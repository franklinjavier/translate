import Foundation
import Testing
@testable import Translate

struct ClipboardTransactionsTests {
  let pasteboard = FakePasteboard("user clipboard")
  let app: FakeFrontApp

  init() {
    app = FakeFrontApp(pasteboard: pasteboard, selection: "selected")
  }

  /// Who wrote a change can't be proven, so the copy stays as if the user had pressed ⌘C.
  @Test func copyReturnsTheSelectionAndLeavesIt() async throws {
    let copied = try await app.transactions().copySelection()
    #expect(copied == "selected")
    #expect(pasteboard.contents == "selected")
  }

  @Test func twoWritesAfterCopyAreAmbiguous() async throws {
    let transactions = ClipboardTransactions(
      pasteboard: pasteboard,
      timing: .fast,
      modifiersHeld: { false },
      postKey: { [pasteboard] _ in
        pasteboard.copied("selected")
        pasteboard.copied("someone else")
      }
    )
    #expect(try await transactions.copySelection() == nil)
    #expect(pasteboard.contents == "someone else")
  }

  @Test func lateAnswerAfterTheTimeoutIsNotTaken() async throws {
    app.copyDelay = .milliseconds(150)
    #expect(try await app.transactions().copySelection() == nil)
  }

  @Test func appSwitchDuringCopyDiscardsIt() async throws {
    var frontmost = true
    app.copyDelay = .milliseconds(5)
    let transactions = app.transactions()
    let copy = Task { try await transactions.copySelection(isAppCurrent: { frontmost }) }
    try await eventually { app.keys == [.copy] }
    frontmost = false
    #expect(try await copy.value == nil)
  }

  @Test func copyWithNoAnswerLeavesThePasteboardAlone() async throws {
    app.selection = nil
    let before = pasteboard.changeCount
    let copied = try await app.transactions().copySelection()
    #expect(copied == nil)
    #expect(pasteboard.changeCount == before)
  }

  @Test func verifiedPasteRestoresWhatItReplaced() async throws {
    let outcome = try await app.transactions().paste("tradução", validation: .check { true }, verify: { true })
    #expect(outcome == .pasted(verified: true))
    #expect(app.pasted == ["tradução"])
    #expect(pasteboard.contents == "user clipboard")
  }

  /// A slow target may read after any wait, so only a confirmed paste gets the old contents back.
  @Test func unverifiedPasteLeavesTheTranslation() async throws {
    let outcome = try await app.transactions().paste("tradução", validation: .check { true }, verify: { false })
    #expect(outcome == .pasted(verified: false))
    #expect(pasteboard.contents == "tradução")
  }

  @Test func ignoredPasteLeavesTheTranslationInPlace() async throws {
    app.readsPaste = false
    let outcome = try await app.transactions().paste("tradução", validation: .check { true }, verify: { false })
    #expect(outcome == .pasted(verified: false))
    #expect(app.keys == [.paste])
    #expect(pasteboard.contents == "tradução")
  }

  @Test func newerContentsFromTheUserAreNeverOverwritten() async throws {
    app.afterPaste = { [pasteboard] in pasteboard.copied("copied by the user meanwhile") }
    _ = try await app.transactions().paste("tradução", validation: .check { true }, verify: { true })
    #expect(pasteboard.contents == "copied by the user meanwhile")
  }

  @Test func failedValidationPostsNothing() async throws {
    let outcome = try await app.transactions().paste("tradução", validation: .check { false }, verify: { false })
    #expect(outcome == .selectionChanged)
    #expect(app.keys.isEmpty)
    #expect(pasteboard.contents == "user clipboard")
  }

  /// Cancelled while waiting for the shortcut's modifiers: no key, nothing written.
  @Test func cancellationBeforePastingPostsNothing() async throws {
    let transactions = ClipboardTransactions(
      pasteboard: pasteboard,
      timing: ClipboardTransactions.Timing(modifierWait: .seconds(5)),
      modifiersHeld: { true },
      postKey: { [app] in app.post($0) }
    )
    let task = Task { try await transactions.paste("tradução", validation: .check { true }, verify: { false }) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(app.keys.isEmpty)
    #expect(pasteboard.contents == "user clipboard")
  }

  /// A paste requested while a slow copy runs waits for the copy to restore first. Had it
  /// run at once, the copy would have read the translation as the selection.
  @Test func captureAndReplacementNeverOverlap() async throws {
    app.copyDelay = .milliseconds(20)
    let transactions = app.transactions()
    let copied = Task { try await transactions.copySelection() }
    try await eventually { app.keys == [.copy] }
    let pasted = Task { try await transactions.paste("tradução", validation: .check { true }, verify: { false }) }
    let (copy, paste) = try await (copied.value, pasted.value)
    #expect(copy == "selected")
    #expect(paste == .pasted(verified: false))
    #expect(app.keys == [.copy, .paste])
    #expect(app.pasted == ["tradução"])
  }

  @Test func cancelledWaiterLeavesTheQueueWithoutRunning() async throws {
    app.selection = nil  // the copy holds the gate until its timeout
    let transactions = app.transactions()
    let copy = Task { try await transactions.copySelection() }
    try await eventually { app.keys == [.copy] }
    let paste = Task { try await transactions.paste("tradução", validation: .check { true }, verify: { false }) }
    try await Task.sleep(for: .milliseconds(5))
    paste.cancel()
    await #expect(throws: CancellationError.self) { try await paste.value }
    _ = try await copy.value
    #expect(app.keys == [.copy])
  }
}

struct AsyncGateTests {
  /// Release hands the lock straight to the next waiter; one cancelled by then must not run.
  @Test func waiterCancelledAsTheLockArrivesDoesNotRun() async throws {
    let gate = AsyncGate()
    var ran = false
    var waiter: Task<Void, Error>?
    try await gate.withLock {
      waiter = Task { try await gate.withLock { ran = true } }
      await Task.yield()
      waiter?.cancel()
    }
    await #expect(throws: CancellationError.self) { try await waiter?.value }
    #expect(!ran)
    try await gate.withLock {}
  }

  @Test func runsInArrivalOrder() async throws {
    let gate = AsyncGate()
    var order: [Int] = []
    let first = Task {
      try await gate.withLock {
        try await Task.sleep(for: .milliseconds(20))
        order.append(1)
      }
    }
    try await Task.sleep(for: .milliseconds(2))
    let second = Task { try await gate.withLock { order.append(2) } }
    let third = Task { try await gate.withLock { order.append(3) } }
    _ = try await (first.value, second.value, third.value)
    #expect(order == [1, 2, 3])
  }
}
