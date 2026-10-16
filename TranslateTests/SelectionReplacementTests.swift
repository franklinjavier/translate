import Foundation
import Testing
@testable import Translate

struct SelectionReplacementTests {
  let pasteboard = FakePasteboard("user clipboard")
  let app: FakeFrontApp

  init() {
    app = FakeFrontApp(pasteboard: pasteboard)
  }

  func replacer(frontmost: pid_t? = 42) -> SelectionReplacer {
    SelectionReplacer(frontmostPID: { frontmost }, clipboard: app.transactions())
  }

  // MARK: Accessibility

  /// The previous check required the source phrase to be gone from the whole value, so the
  /// earlier copy failed it and triggered a second write and then a first-occurrence splice.
  @Test func duplicatePhraseElsewhereIsReplacedOnceAtTheSelection() async throws {
    let editor = FakeEditor("hello world. hello world.", selecting: "hello world", occurrence: 2)
    let outcome = try await replacer().replace(editor.capture(), with: "olá mundo")
    #expect(outcome == .verified)
    #expect(editor.text == "hello world. olá mundo.")
    #expect(editor.writes == ["selectedText"])
    #expect(app.keys.isEmpty)
  }

  @Test func repeatedSelectedTextKeepsEveryOtherCopy() async throws {
    let editor = FakeEditor("ok ok ok", selecting: "ok", occurrence: 2)
    let outcome = try await replacer().replace(editor.capture(), with: "tá")
    #expect(outcome == .verified)
    #expect(editor.text == "ok tá ok")
  }

  @Test func acceptedWriteThatChangesNothingIsUnverifiedAndNeverRepeated() async throws {
    let editor = FakeEditor("one two three", selecting: "two")
    editor.ignoresAcceptedSelectedText = true
    let outcome = try await replacer().replace(editor.capture(), with: "dois")
    #expect(outcome == .unverified)
    #expect(editor.writes == ["selectedText"])
    #expect(editor.text == "one two three")
    #expect(app.keys.isEmpty)
  }

  @Test func refusedSelectedTextSplicesTheCapturedRangeNotTheFirstMatch() async throws {
    let editor = FakeEditor("same, same", selecting: "same", occurrence: 2)
    editor.acceptsSelectedText = false
    let outcome = try await replacer().replace(editor.capture(), with: "igual")
    #expect(outcome == .verified)
    #expect(editor.text == "same, igual")
    #expect(editor.writes == ["selectedText", "value"])
  }

  @Test func unreadableValueMeansAnAcceptedWriteStaysUnverified() async throws {
    let editor = FakeEditor("a b c", selecting: "b")
    editor.exposesValue = false
    let captured = editor.capture()
    let outcome = try await replacer().replace(captured, with: "B")
    #expect(outcome == .unverified)
    #expect(editor.writes == ["selectedText"])
  }

  // MARK: Stale selections

  @Test func sameTextSelectedAtAnotherPlaceIsRefused() async throws {
    let editor = FakeEditor("hello world. hello world.", selecting: "hello world")
    let captured = editor.capture()
    editor.selection = NSRange(location: 13, length: 11)
    #expect(editor.selectedText == captured.text)

    let outcome = try await replacer().replace(captured, with: "olá mundo")
    #expect(outcome == .failed(.selectionChanged))
    #expect(editor.writes.isEmpty)
    #expect(app.keys.isEmpty)
  }

  @Test func editedDocumentWithTheSameRangeIsRefused() async throws {
    let editor = FakeEditor("draft one", selecting: "one")
    let captured = editor.capture()
    editor.text = "DRAFT one"
    let outcome = try await replacer().replace(captured, with: "um")
    #expect(outcome == .failed(.selectionChanged))
    #expect(editor.writes.isEmpty)
  }

  @Test func anotherAppInFrontIsRefused() async throws {
    let editor = FakeEditor("text", selecting: "text")
    let outcome = try await replacer(frontmost: 7).replace(editor.capture(), with: "texto")
    #expect(outcome == .failed(.appChanged))
    #expect(editor.writes.isEmpty)
    #expect(app.keys.isEmpty)
  }

  /// Another field in the same app keeps the old range and value; only focus tells them apart.
  @Test func focusMovedToAnotherFieldIsRefused() async throws {
    let editor = FakeEditor("text", selecting: "text")
    let captured = editor.capture()
    editor.isFocused = false
    let outcome = try await replacer().replace(captured, with: "texto")
    #expect(outcome == .failed(.selectionChanged))
    #expect(editor.writes.isEmpty)
    #expect(app.keys.isEmpty)
  }

  @Test func clipboardCaptureInAFieldThatLostFocusIsNotPasted() async throws {
    app.selection = "selected words"
    let field = FakeEditor("selected words", selecting: "selected words")
    let captured = CapturedSelection(
      text: "selected words", source: .clipboard, appPID: 42, element: field, range: nil, value: nil
    )
    field.isFocused = false
    let outcome = try await replacer().replace(captured, with: "palavras")
    #expect(outcome == .failed(.selectionChanged))
    #expect(!app.keys.contains(.paste))
  }

  @Test func cancelledBeforeWritingChangesNothing() async throws {
    let editor = FakeEditor("text", selecting: "text")
    let replacer = replacer()
    let captured = editor.capture()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await replacer.replace(captured, with: "texto")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(editor.writes.isEmpty)
  }

  // MARK: Paste fallback

  @Test func refusedWritesFallBackToAValidatedPasteThatAccessibilityConfirms() async throws {
    let editor = FakeEditor("keep this one", selecting: "this")
    editor.acceptsSelectedText = false
    editor.acceptsValue = false
    app.editor = editor
    let outcome = try await replacer().replace(editor.capture(), with: "isto")
    #expect(outcome == .verified)
    #expect(editor.text == "keep isto one")
    #expect(app.keys == [.paste])
    #expect(pasteboard.contents == "user clipboard")
  }

  @Test func clipboardCaptureIsRecopiedBeforePastingAndStaysUnverified() async throws {
    app.selection = "selected words"
    let captured = CapturedSelection(
      text: "selected words", source: .clipboard, appPID: 42, element: nil, range: nil, value: nil
    )
    let outcome = try await replacer().replace(captured, with: "palavras")
    #expect(outcome == .unverified)
    #expect(app.keys == [.copy, .paste])
    #expect(app.pasted == ["palavras"])
    #expect(pasteboard.contents == "palavras", "unconfirmed, so nothing is restored over a slow paste")
  }

  @Test func clipboardCaptureWhoseSelectionChangedIsNotPasted() async throws {
    app.selection = "something else"
    let captured = CapturedSelection(
      text: "selected words", source: .clipboard, appPID: 42, element: nil, range: nil, value: nil
    )
    let outcome = try await replacer().replace(captured, with: "palavras")
    #expect(outcome == .failed(.selectionChanged))
    #expect(app.keys == [.copy])
  }
}

struct CapturedSelectionTests {
  @Test func expectedValueSplicesUTF16Range() {
    let editor = FakeEditor("café 👋🏽 done", selecting: "done")
    #expect(editor.capture().expectedValue(replacingWith: "feito") == "café 👋🏽 feito")
  }

  @Test func withoutRangeOrValueOnlySelectedTextDecides() {
    let editor = FakeEditor("abc", selecting: "b")
    let captured = CapturedSelection(text: "b", source: .accessibility, appPID: 1, element: editor, range: nil, value: nil)
    #expect(captured.isCurrent(in: editor))
    editor.selection = NSRange(location: 0, length: 1)
    #expect(!captured.isCurrent(in: editor))
  }
}
