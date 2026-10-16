import Foundation
import Testing
@testable import Translate

struct TranslationReliabilityTests {
  @Test func copiedSelectionCannotMoveToAnIdenticalPhraseInTheSameField() async throws {
    let editor = FakeEditor("hello ... hello", selecting: "hello")
    let captured = editor.capture()
    let selection = CapturedSelection(
      text: captured.text,
      source: .clipboard,
      appPID: captured.appPID,
      element: editor,
      range: captured.range,
      value: captured.value
    )
    editor.selection = NSRange(location: 10, length: 5)
    let board = FakePasteboard("previous clipboard")
    let app = FakeFrontApp(pasteboard: board, selection: "hello")
    app.editor = editor
    let replacer = SelectionReplacer(frontmostPID: { 42 }, clipboard: app.transactions())
    let outcome = try await replacer.replace(selection, with: "olá")
    #expect(outcome == .failed(.selectionChanged))
    #expect(editor.text == "hello ... hello")
    #expect(app.pasted.isEmpty)
  }

  @Test func unknownClaudeEventNamesCannotLeakContentIntoDiagnostics() {
    var parser = ClaudeStreamParser()
    let pulse = parser.consume(
      #"{"type":"stream_event","event":{"type":"PRIVATE_SENTINEL_CONTENT"}}"# + "\n"
    )
    #expect(!pulse.traces.joined().contains("PRIVATE_SENTINEL_CONTENT"))
  }

  @Test func unrelatedClipboardUpdateDuringCopyIsNotRestoredOver() async throws {
    let board = FakePasteboard("previous clipboard")
    let clipboard = ClipboardTransactions(
      pasteboard: board,
      timing: .fast,
      modifiersHeld: { false },
      postKey: { key in
        if key == .copy {
          // Another app changes the clipboard while the source app never answers Copy.
          board.copied("new content from the user")
        }
      }
    )
    _ = try await clipboard.copySelection()
    #expect(board.contents == "new content from the user")
  }

  @Test func unverifiedSlowPasteDoesNotReceiveThePreviousClipboard() async throws {
    let board = FakePasteboard("previous clipboard")
    var consumer: Task<String?, Never>?
    let clipboard = ClipboardTransactions(
      pasteboard: board,
      timing: .fast,
      modifiersHeld: { false },
      postKey: { key in
        if key == .paste {
          consumer = Task {
            try? await Task.sleep(for: .milliseconds(40))
            return board.contents
          }
        }
      }
    )
    _ = try await clipboard.paste("the translation", validation: .check { true }, verify: { false })
    let consumed = await consumer?.value
    #expect(consumed == "the translation")
  }

  @Test func clipboardManagerReadingFirstDoesNotCountAsTheTargetPasting() async throws {
    let board = FakePasteboard("previous clipboard")
    var consumer: Task<String?, Never>?
    let clipboard = ClipboardTransactions(
      pasteboard: board,
      timing: .fast,
      modifiersHeld: { false },
      postKey: { key in
        if key == .paste {
          // A clipboard history app reads immediately; the intended target reads later.
          _ = board.contents
          consumer = Task {
            try? await Task.sleep(for: .milliseconds(40))
            return board.contents
          }
        }
      }
    )
    _ = try await clipboard.paste("the translation", validation: .check { true }, verify: { false })
    let consumed = await consumer?.value
    #expect(consumed == "the translation")
  }

  @Test func failedCaptureShowsAnErrorInsteadOfLoadingForever() async throws {
    let overlay = OverlayState()
    let presenter = RecordingPresenter()
    let session = TranslationCoordinator(
      overlay: overlay,
      presenter: presenter,
      boundaries: SessionBoundaries(
        anchor: { .point(.zero) },
        isTrusted: { true },
        capture: { throw CaptureFailure() },
        translate: { _, _ in "unused" },
        replace: { _, _ in .failed(.selectionChanged) }
      )
    )
    session.translate(
      to: .english,
      configuration: EngineConfiguration(engine: .claude, executableOverride: "", model: "")
    )
    defer { session.dismiss() }
    try await eventually(timeout: .milliseconds(100)) {
      if case .error = overlay.phase { return true }
      return false
    }
  }
}

private struct CaptureFailure: Error {}
