import Foundation
import Testing
@testable import Translate

/// The capture function itself, with the frontmost app and focused element supplied by the
/// test. Editors hide their selected text, as some apps do, so capture has to copy it.
struct TextCaptureTests {
  let board = FakePasteboard("user clipboard")
  let text = "hello world, hello world"
  let editor: FakeEditor
  let app: FakeFrontApp
  /// Where the same phrase appears a second time.
  let secondPhrase: NSRange

  init() {
    editor = FakeEditor(text, selecting: "hello world")
    editor.exposesSelectedText = false
    secondPhrase = FakeEditor(text, selecting: "hello world", occurrence: 2).selection
    app = FakeFrontApp(pasteboard: board, selection: "hello world")
  }

  func capture(
    _ clipboard: ClipboardTransactions,
    frontmost: @escaping () -> pid_t? = { 42 },
    focused: (any SelectionElement)?
  ) async throws -> CaptureResult {
    try await TextCapture.capture(using: clipboard, frontmostPID: frontmost, focusedElement: { focused })
  }

  /// Transactions whose ⌘C reaches the app, then runs `afterCopy` while the answer is pending.
  func transactions(afterCopy: @escaping () -> Void) -> ClipboardTransactions {
    ClipboardTransactions(
      pasteboard: board,
      timing: .fast,
      modifiersHeld: { false },
      postKey: { [app] key in
        app.post(key)
        if key == .copy { afterCopy() }
      }
    )
  }

  /// Modifiers stay held once, while `whileHeld` runs.
  func transactions(whileHeld: @escaping () -> Void) -> ClipboardTransactions {
    var held = true
    return app.transactions(modifiersHeld: {
      guard held else { return false }
      held = false
      whileHeld()
      return true
    })
  }

  // MARK: Position changes while waiting

  @Test func selectionMovedToAnIdenticalPhraseWhileModifiersAreHeldIsNotCaptured() async throws {
    let clipboard = transactions(whileHeld: { editor.selection = secondPhrase })
    let result = try await capture(clipboard, focused: editor)
    #expect(result.isEmpty)
    #expect(app.keys.isEmpty)
  }

  @Test func selectionMovedToAnIdenticalPhraseWhileCopyIsPendingIsNotCaptured() async throws {
    let clipboard = transactions(afterCopy: { editor.selection = secondPhrase })
    let result = try await capture(clipboard, focused: editor)
    #expect(result.isEmpty)
    #expect(result.selection?.range != secondPhrase)
  }

  @Test func anotherFieldInTheSameAppTakingFocusIsNotCaptured() async throws {
    let other = FakeEditor("hello world", selecting: "hello world")
    var focused: any SelectionElement = editor
    let clipboard = transactions(whileHeld: {
      editor.isFocused = false
      focused = other
    })
    let result = try await TextCapture.capture(
      using: clipboard,
      frontmostPID: { 42 },
      focusedElement: { focused }
    )
    #expect(result.isEmpty)
    #expect(app.keys.isEmpty)
  }

  @Test func sourceAppChangingWhileModifiersAreHeldPostsNoCopy() async throws {
    var frontmost: pid_t = 42
    let clipboard = transactions(whileHeld: { frontmost = 7 })
    let result = try await capture(clipboard, frontmost: { frontmost }, focused: editor)
    #expect(result.isEmpty)
    #expect(app.keys.isEmpty)
  }

  @Test func sourceAppChangingWhileCopyIsPendingIsNotCaptured() async throws {
    var frontmost: pid_t = 42
    let clipboard = transactions(afterCopy: { frontmost = 7 })
    let result = try await capture(clipboard, frontmost: { frontmost }, focused: editor)
    #expect(result.isEmpty)
  }

  @Test func valueEditedWhileCopyIsPendingIsNotCaptured() async throws {
    let clipboard = transactions(afterCopy: { editor.text += "!" })
    let result = try await capture(clipboard, focused: editor)
    #expect(result.isEmpty)
    #expect(result.selection?.value != text + "!")
  }

  // MARK: What was copied

  @Test func clipboardTextThatIsNotTheKnownRangeIsRejected() async throws {
    // The app ignores ⌘C and something else writes the pasteboard instead.
    app.selection = nil
    let clipboard = transactions(afterCopy: { board.copied("unrelated clipboard text") })
    let result = try await capture(clipboard, focused: editor)
    #expect(result.isEmpty)
    #expect(board.contents == "unrelated clipboard text")
  }

  @Test func unchangedSelectionKeepsTheRangeAndValueFromBeforeTheCopy() async throws {
    let original = editor.selection
    let result = try await capture(app.transactions(), focused: editor)
    let selection = try #require(result.selection)
    #expect(selection.text == "hello world")
    #expect(selection.source == .clipboard)
    #expect(selection.appPID == 42)
    #expect(selection.element === editor)
    #expect(selection.range == original)
    #expect(selection.value == text)
    #expect(app.keys == [.copy])
  }

  @Test func appWithoutRangeOrValueStillCopies() async throws {
    editor.exposesRange = false
    editor.exposesValue = false
    app.selection = "whatever the app copies"
    let result = try await capture(app.transactions(), focused: editor)
    let selection = try #require(result.selection)
    #expect(selection.text == "whatever the app copies")
    #expect(selection.range == nil)
    #expect(selection.value == nil)
  }

  @Test func appWithoutAnAccessibleElementStillCopies() async throws {
    let result = try await capture(app.transactions(), focused: nil)
    let selection = try #require(result.selection)
    #expect(selection.text == "hello world")
    #expect(selection.element == nil)
  }

  @Test func overlongSelectionIsRejectedRatherThanClipped() async throws {
    let long = String(repeating: "a", count: CapturedSelection.maxCharacters + 1)
    let copied = FakeEditor(long, selecting: long)
    copied.exposesSelectedText = false
    app.selection = long
    #expect(try await capture(app.transactions(), focused: copied).isTooLong)

    let readable = FakeEditor(long, selecting: long)
    #expect(try await capture(app.transactions(), focused: readable).isTooLong)
  }

  @Test func invalidOrOverflowingRangesAreEmptyAndPostNoCopy() async throws {
    let ranges = [
      NSRange(location: 1, length: Int.max),
      NSRange(location: -1, length: 1),
      NSRange(location: 0, length: -1),
      NSRange(location: NSNotFound, length: 0),
    ]
    for range in ranges {
      editor.selection = range
      let result = try await capture(app.transactions(), focused: editor)
      #expect(result.isEmpty)
    }
    #expect(app.keys.isEmpty)
  }

  // MARK: Cancellation

  @Test func cancelledCaptureThrowsOnTheAccessibilityPath() async throws {
    let readable = FakeEditor("one two", selecting: "two")
    let clipboard = app.transactions()
    let task = Task { try await capture(clipboard, focused: readable) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func cancelledCapturePostsNoKeys() async throws {
    let clipboard = app.transactions()
    let task = Task { [editor] in try await capture(clipboard, focused: editor) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(app.keys.isEmpty)
    #expect(board.contents == "user clipboard")
  }
}

private extension CaptureResult {
  var selection: CapturedSelection? {
    if case .selection(let selection) = self { return selection }
    return nil
  }

  var isEmpty: Bool {
    if case .empty = self { return true }
    return false
  }

  var isTooLong: Bool {
    if case .tooLong = self { return true }
    return false
  }
}
