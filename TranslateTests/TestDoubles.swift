import AppKit
import Foundation
@testable import Translate

/// An editor held in memory: a value, a UTF-16 selection, and switches for how a real app
/// may treat Accessibility writes.
final class FakeEditor: SelectionElement {
  var text: String
  var selection: NSRange
  var exposesValue = true
  var exposesRange = true
  /// False models an app that reports range and value but not the selected text, so a
  /// capture has to copy it through the pasteboard.
  var exposesSelectedText = true
  var acceptsSelectedText = true
  /// Reports success for a selected-text write but changes nothing, like some web views.
  var ignoresAcceptedSelectedText = false
  var acceptsValue = true
  /// False once the user moves focus to another field.
  var isFocused = true
  private(set) var writes: [String] = []

  init(_ text: String, selecting substring: String, occurrence: Int = 1) {
    self.text = text
    var searchStart = text.startIndex
    var found: Range<String.Index>?
    for _ in 0..<occurrence {
      found = text.range(of: substring, range: searchStart..<text.endIndex)
      searchStart = found?.upperBound ?? text.endIndex
    }
    selection = NSRange(found!, in: text)
  }

  var selectedText: String? { exposesSelectedText ? selectedSubstring : nil }
  private var selectedSubstring: String { (text as NSString).substring(with: selection) }
  var selectedRange: NSRange? { exposesRange ? selection : nil }
  var value: String? { exposesValue ? text : nil }

  func setSelectedText(_ replacement: String) -> Bool {
    writes.append("selectedText")
    guard acceptsSelectedText else { return false }
    if !ignoresAcceptedSelectedText {
      insert(replacement)
    }
    return true
  }

  func setValue(_ value: String) -> Bool {
    writes.append("value")
    guard acceptsValue else { return false }
    text = value
    selection = NSRange(location: 0, length: 0)
    return true
  }

  /// What a real app does on paste or a selected-text write: replace the selection, caret after.
  func insert(_ replacement: String) {
    text = (text as NSString).replacingCharacters(in: selection, with: replacement)
    selection = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
  }

  func capture(pid: pid_t = 42) -> CapturedSelection {
    CapturedSelection(
      text: selectedSubstring,
      source: .accessibility,
      appPID: pid,
      element: self,
      range: selectedRange,
      value: value
    )
  }
}

final class FakePasteboard: PasteboardAccess {
  private(set) var changeCount = 0
  private(set) var contents: String?

  init(_ contents: String? = nil) {
    self.contents = contents
  }

  func string() -> String? { contents }

  func snapshot() -> PasteboardSnapshot {
    PasteboardSnapshot(items: contents.map { [[.string: Data($0.utf8)]] } ?? [])
  }

  func write(_ text: String) -> Int {
    changeCount += 1
    contents = text
    return changeCount
  }

  func restore(_ snapshot: PasteboardSnapshot) {
    changeCount += 1
    contents = snapshot.items.first?[.string].map { String(decoding: $0, as: UTF8.self) }
  }

  /// The user, or the frontmost app answering ⌘C, puts something on the pasteboard.
  func copied(_ text: String) {
    changeCount += 1
    contents = text
  }
}

/// The frontmost app as the pasteboard sees it: answers ⌘C with its selection and records
/// what each ⌘V pasted.
final class FakeFrontApp {
  let pasteboard: FakePasteboard
  var selection: String?
  var editor: FakeEditor?
  /// Delay before the app's copy lands on the pasteboard.
  var copyDelay: Duration?
  /// Runs right after a paste is read, e.g. the user copying something newer.
  var afterPaste: (() -> Void)?
  /// False models an app that ignores ⌘V.
  var readsPaste = true
  private(set) var keys: [SyntheticKey] = []
  private(set) var pasted: [String] = []

  init(pasteboard: FakePasteboard, selection: String? = nil) {
    self.pasteboard = pasteboard
    self.selection = selection
  }

  func post(_ key: SyntheticKey) {
    keys.append(key)
    switch key {
    case .copy:
      guard let selection else { return }
      if let copyDelay {
        Task {
          try? await Task.sleep(for: copyDelay)
          self.pasteboard.copied(selection)
        }
      } else {
        pasteboard.copied(selection)
      }
    case .paste:
      guard readsPaste else { return }
      let contents = pasteboard.contents ?? ""
      pasted.append(contents)
      editor?.insert(contents)
      afterPaste?()
    }
  }

  func transactions(modifiersHeld: @escaping () -> Bool = { false }) -> ClipboardTransactions {
    ClipboardTransactions(
      pasteboard: pasteboard,
      timing: .fast,
      modifiersHeld: modifiersHeld,
      postKey: { [unowned self] in self.post($0) }
    )
  }
}

extension ClipboardTransactions.Timing {
  static let fast = ClipboardTransactions.Timing(
    poll: .milliseconds(1),
    modifierWait: .milliseconds(10),
    copyTimeout: .milliseconds(60),
    pasteSettle: .milliseconds(30)
  )
}

/// An async call a test resumes when it chooses. `honorsCancellation` decides whether a
/// cancelled caller is released at once or keeps waiting, like a boundary that ignores it.
final class Pending<Value> {
  private var continuation: CheckedContinuation<Value, Error>?
  private(set) var calls = 0
  private(set) var sawCancellation = false
  let honorsCancellation: Bool

  init(honorsCancellation: Bool = true) {
    self.honorsCancellation = honorsCancellation
  }

  var isWaiting: Bool { continuation != nil }

  func wait() async throws -> Value {
    calls += 1
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
      }
    } onCancel: {
      Task { @MainActor in self.cancelled() }
    }
  }

  func resume(_ value: sending Value) {
    continuation?.resume(returning: value)
    continuation = nil
  }

  func fail(_ error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  private func cancelled() {
    sawCancellation = true
    if honorsCancellation {
      fail(CancellationError())
    }
  }
}

final class RecordingPresenter: OverlayPresenter {
  private(set) var presented = 0
  private(set) var hidden = 0

  func present(anchor: OverlayAnchor) { presented += 1 }
  func relayout(animated: Bool) {}
  func hide() { hidden += 1 }
}

/// Lets queued main-actor work run until `condition` holds, failing after `timeout`.
func eventually(
  timeout: Duration = .seconds(2),
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      throw EventuallyTimeout()
    }
    try await Task.sleep(for: .milliseconds(1))
  }
}

struct EventuallyTimeout: Error {}
