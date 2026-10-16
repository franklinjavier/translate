import AppKit
import Carbon.HIToolbox

/// The pasteboard calls a transaction needs. `NSPasteboard.general` in the app, an in-memory
/// board in tests.
protocol PasteboardAccess: AnyObject {
  var changeCount: Int { get }
  func string() -> String?
  func snapshot() -> PasteboardSnapshot
  /// Replaces the contents and returns the change count that marks them as ours.
  func write(_ text: String) -> Int
  func restore(_ snapshot: PasteboardSnapshot)
}

struct PasteboardSnapshot {
  var items: [[NSPasteboard.PasteboardType: Data]]
}

nonisolated enum SyntheticKey: Sendable {
  case copy
  case paste
}

/// How a paste decides the selection it replaces is still the one that was translated.
enum PasteValidation {
  /// Accessibility can read the selection; the closure compares it with the capture.
  case check(() -> Bool)
  /// Nothing to read, so copy the selection again and compare the text. `isAppCurrent` also
  /// checks any position the capture recorded, before and after the copy.
  case recopy(expected: String, isAppCurrent: () -> Bool)
}

enum PasteOutcome: Equatable {
  /// ⌘V was posted. `verified` only when Accessibility read back the expected value.
  case pasted(verified: Bool)
  case selectionChanged
}

/// Every copy and paste that borrows the user's pasteboard runs here, one at a time and in
/// order, so a capture never interleaves with a replacement. A paste restores the previous
/// contents only once Accessibility confirms the text landed and only while the pasteboard
/// still holds exactly what the paste wrote; anything newer belongs to the user and stays.
final class ClipboardTransactions {
  struct Timing {
    /// Polling interval while waiting for modifiers or the pasteboard.
    var poll: Duration = .milliseconds(8)
    /// Wait for the shortcut's modifiers to be released before posting keys.
    var modifierWait: Duration = .milliseconds(160)
    /// Wait for the frontmost app to answer ⌘C.
    var copyTimeout: Duration = .milliseconds(250)
    /// How long Accessibility gets to show the pasted text. Only a read-back of the expected
    /// value proves the paste; without one the translation stays on the pasteboard, so a
    /// slow paste can never insert the previous contents instead.
    var pasteSettle: Duration = .milliseconds(500)
  }

  private let pasteboard: any PasteboardAccess
  private let postKey: (SyntheticKey) -> Void
  private let modifiersHeld: () -> Bool
  private let timing: Timing
  private let gate = AsyncGate()

  init(
    pasteboard: any PasteboardAccess,
    timing: Timing = Timing(),
    modifiersHeld: @escaping () -> Bool,
    postKey: @escaping (SyntheticKey) -> Void
  ) {
    self.pasteboard = pasteboard
    self.timing = timing
    self.modifiersHeld = modifiersHeld
    self.postKey = postKey
  }

  static func live() -> ClipboardTransactions {
    ClipboardTransactions(
      pasteboard: SystemPasteboard(),
      modifiersHeld: { !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty },
      postKey: SyntheticKeys.post
    )
  }

  /// Copies the frontmost app's selection. Nil when it didn't answer, when another write
  /// made the answer ambiguous, or when `isAppCurrent` fails before or after the copy.
  ///
  /// The copy stays on the pasteboard, as if the user had pressed ⌘C: the pasteboard can't
  /// say who wrote a change, so restoring could overwrite something newer from someone else.
  func copySelection(isAppCurrent: () -> Bool = { true }) async throws -> String? {
    try await gate.withLock {
      try await waitForModifiers()
      guard isAppCurrent() else { return nil }
      let copied = await copyLocked()
      try Task.checkCancellation()
      return isAppCurrent() ? copied : nil
    }
  }

  /// Pastes `text` over the selection once `validation` passes, then restores the pasteboard.
  /// Cancellation is honored until ⌘V is posted; after that the transaction always finishes
  /// its restore. `verify` may confirm the paste through Accessibility while it settles.
  func paste(_ text: String, validation: PasteValidation, verify: @escaping () -> Bool) async throws -> PasteOutcome {
    try await gate.withLock {
      try await waitForModifiers()
      switch validation {
      case .check(let isCurrent):
        guard isCurrent() else { return .selectionChanged }
      case .recopy(let expected, let isAppCurrent):
        guard isAppCurrent() else { return .selectionChanged }
        let copied = await copyLocked()
        try Task.checkCancellation()
        guard copied == expected, isAppCurrent() else { return .selectionChanged }
      }

      let saved = pasteboard.snapshot()
      let owned = pasteboard.write(text)
      if Task.isCancelled {
        restore(saved, ifStill: owned)
        throw CancellationError()
      }
      postKey(.paste)

      // Not cancellable: the paste is out, and only a confirmed one gives the pasteboard back.
      var verified = false
      let deadline = ContinuousClock.now + timing.pasteSettle
      while !verified, ContinuousClock.now < deadline {
        await Self.pause(timing.poll)
        verified = verify()
      }
      if verified {
        restore(saved, ifStill: owned)
      }
      return .pasted(verified: verified)
    }
  }

  // MARK: Inside the gate

  /// Posts ⌘C and waits for exactly one new write. More than one means someone else wrote
  /// too, and the text can't be attributed to the selection.
  private func copyLocked() async -> String? {
    let before = pasteboard.changeCount
    postKey(.copy)

    // Not cancellable: once ⌘C is posted, the answer is waited for either way.
    let deadline = ContinuousClock.now + timing.copyTimeout
    while ContinuousClock.now < deadline {
      let count = pasteboard.changeCount
      if count == before + 1, let text = pasteboard.string() {
        return pasteboard.changeCount == count ? text : nil
      }
      if count > before + 1 { return nil }
      await Self.pause(timing.poll)
    }
    return nil
  }

  private func waitForModifiers() async throws {
    let deadline = ContinuousClock.now + timing.modifierWait
    while modifiersHeld(), ContinuousClock.now < deadline {
      try await Task.sleep(for: timing.poll)
    }
    try Task.checkCancellation()
  }

  private func restore(_ snapshot: PasteboardSnapshot, ifStill owned: Int) {
    guard pasteboard.changeCount == owned else { return }
    pasteboard.restore(snapshot)
  }

  /// A sleep cancellation can't cut short, for waits that protect the user's pasteboard.
  private static func pause(_ duration: Duration) async {
    await Task { try? await Task.sleep(for: duration) }.value
  }
}

/// A FIFO async lock on the main actor. Waiters that are cancelled leave the queue and throw.
final class AsyncGate {
  private var locked = false
  private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
  private var nextID = 0

  func withLock<T>(_ body: () async throws -> T) async throws -> T {
    try await acquire()
    defer { release() }
    // The lock may have been handed over just before a cancellation was processed.
    try Task.checkCancellation()
    return try await body()
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    guard locked else {
      locked = true
      return
    }
    let id = nextID
    nextID += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append((id, continuation))
      }
    } onCancel: {
      Task { @MainActor in self.cancelWaiter(id) }
    }
  }

  /// Hands the lock straight to the next waiter, so nobody can barge in between.
  private func release() {
    if waiters.isEmpty {
      locked = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  private func cancelWaiter(_ id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

final class SystemPasteboard: PasteboardAccess {
  private let pasteboard = NSPasteboard.general
  /// Asks clipboard managers not to record the translation while it passes through.
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  var changeCount: Int { pasteboard.changeCount }

  func string() -> String? {
    pasteboard.string(forType: .string)
  }

  func snapshot() -> PasteboardSnapshot {
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      })
    }
    return PasteboardSnapshot(items: items)
  }

  func write(_ text: String) -> Int {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data(), forType: Self.transientType)
    pasteboard.writeObjects([item])
    return pasteboard.changeCount
  }

  func restore(_ snapshot: PasteboardSnapshot) {
    pasteboard.clearContents()
    let items = snapshot.items.map { types in
      let item = NSPasteboardItem()
      for (type, data) in types {
        item.setData(data, forType: type)
      }
      return item
    }
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }
}

/// ⌘C and ⌘V posted to the frontmost app, tagged so the overlay's own key tap lets them pass.
nonisolated enum SyntheticKeys {
  static let marker: Int64 = 0x5452_4E53

  static func post(_ key: SyntheticKey) {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    let code = CGKeyCode(key == .copy ? kVK_ANSI_C : kVK_ANSI_V)
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
      event.flags = .maskCommand
      event.setIntegerValueField(.eventSourceUserData, value: marker)
      event.post(tap: .cghidEventTap)
    }
  }
}
