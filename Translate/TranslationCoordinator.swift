import Foundation
import os

private let log = Logger(subsystem: "com.frank.translate", category: "session")

/// The popover as the session drives it. `OverlayPanel` in the app; a recorder in tests.
protocol OverlayPresenter: AnyObject {
  func present(anchor: OverlayAnchor)
  func relayout(animated: Bool)
  func hide()
}

/// A translation as it was asked for: the selection and the engine settings at that moment.
struct TranslationRequest {
  let target: TranslationTarget
  let configuration: EngineConfiguration
  let selection: CapturedSelection
}

/// Everything a session does outside itself. The app passes Accessibility, the pasteboard
/// and the engines; tests pass closures they resume when they choose.
struct SessionBoundaries {
  var anchor: @MainActor () -> OverlayAnchor
  var isTrusted: @MainActor () -> Bool
  var capture: @MainActor () async throws -> CaptureResult
  var translate: @MainActor (TranslationRequest, _ onPartial: @escaping @MainActor (String) -> Void) async throws -> String
  var replace: @MainActor (CapturedSelection, String) async throws -> ReplacementOutcome
}

/// Owns one translation at a time: its capture, engine call and replacement. Starting another
/// or dismissing cancels the work in flight, and a generation check drops any callback from
/// work that was superseded.
final class TranslationCoordinator {
  let overlay: OverlayState
  private let presenter: any OverlayPresenter
  private let boundaries: SessionBoundaries

  private var generation = 0
  private var translationTask: Task<Void, Never>?
  private var replacementTask: Task<Void, Never>?
  private var retryTarget: TranslationTarget?
  /// Kept so Retry translates the same text instead of whatever is selected now.
  private var retrySelection: CapturedSelection?
  /// The request behind the result on screen, which Replace writes back to.
  private var shown: TranslationRequest?

  init(overlay: OverlayState, presenter: any OverlayPresenter, boundaries: SessionBoundaries) {
    self.overlay = overlay
    self.presenter = presenter
    self.boundaries = boundaries
  }

  func translate(to target: TranslationTarget, configuration: EngineConfiguration) {
    start(target: target, configuration: configuration, selection: nil)
  }

  /// Translates the last captured text again, or captures again when there was none
  /// (for example after Accessibility was just granted).
  func retry(configuration: EngineConfiguration) {
    guard let retryTarget else { return }
    start(target: retryTarget, configuration: configuration, selection: retrySelection)
  }

  func dismiss() {
    invalidate()
    overlay.phase = .hidden
    presenter.hide()
  }

  /// Writes the finished translation over the selection it came from. Ignored while streaming
  /// or while a replacement is already running.
  func replace() {
    guard
      replacementTask == nil,
      case .result(_, _, let translation) = overlay.phase,
      let request = shown
    else { return }
    let generation = generation
    replacementTask = Task { [weak self, boundaries] in
      let outcome: ReplacementOutcome
      do {
        outcome = try await boundaries.replace(request.selection, translation)
      } catch {
        guard !(error is CancellationError), let self, generation == self.generation else { return }
        self.replacementTask = nil
        log.error("replacement failed: \(String(describing: type(of: error)), privacy: .public)")
        self.finish(generation: generation, phase: .error(message: Self.replaceFailedMessage, recovery: nil))
        return
      }
      guard let self, generation == self.generation else { return }
      self.replacementTask = nil
      switch outcome {
      case .verified:
        self.overlay.replacedRecently = true
        self.dismiss()
      case .unverified:
        log.info("replacement unverified")
        self.dismiss()
      case .failed(let failure):
        log.info("replacement refused: \(String(describing: failure), privacy: .public)")
        self.finish(generation: generation, phase: .error(message: Self.message(for: failure), recovery: nil))
      }
    }
  }

  // MARK: Private

  private func start(target: TranslationTarget, configuration: EngineConfiguration, selection: CapturedSelection?) {
    let generation = invalidate()
    retryTarget = target
    retrySelection = selection
    // Where the selection is, read before the panel shows and while the source app has focus.
    let anchor = boundaries.anchor()
    overlay.phase = .loading(target: target, source: selection?.text ?? "")
    presenter.present(anchor: anchor)

    translationTask = Task { [weak self, boundaries] in
      let captured: CapturedSelection
      if let selection {
        captured = selection
      } else {
        let result: CaptureResult
        do {
          result = try await boundaries.capture()
        } catch {
          guard !(error is CancellationError), let self else { return }
          log.error("capture failed: \(String(describing: type(of: error)), privacy: .public)")
          self.finish(generation: generation, phase: .error(message: Self.captureFailedMessage, recovery: nil))
          return
        }
        guard let self, generation == self.generation else { return }
        switch result {
        case .selection(let selection):
          captured = selection
          self.retrySelection = selection
        case .tooLong:
          self.finish(generation: generation, phase: .error(message: Self.tooLongMessage, recovery: nil))
          return
        case .empty:
          self.finishWithoutSelection(generation: generation)
          return
        }
      }
      guard let self, generation == self.generation else { return }

      let request = TranslationRequest(target: target, configuration: configuration, selection: captured)
      self.overlay.phase = .loading(target: target, source: captured.text)
      self.presenter.relayout(animated: false)
      do {
        let translation = try await boundaries.translate(request) { [weak self] partial in
          guard let self, generation == self.generation, !Task.isCancelled else { return }
          self.overlay.showPartial(target: target, source: captured.text, translation: partial)
          self.presenter.relayout(animated: true)
        }
        guard generation == self.generation else { return }
        self.shown = request
        self.finish(generation: generation, phase: .result(target: target, source: captured.text, translation: translation))
      } catch is CancellationError {
        return
      } catch {
        guard generation == self.generation else { return }
        let kind = (error as? TranslatorError)?.logSummary ?? String(describing: type(of: error))
        log.error("translation failed: \(kind, privacy: .public)")
        self.finish(generation: generation, phase: .error(message: error.localizedDescription, recovery: .openSettings))
      }
    }
  }

  /// Cancels the translation and replacement in flight; their callbacks no longer apply.
  @discardableResult
  private func invalidate() -> Int {
    generation += 1
    translationTask?.cancel()
    translationTask = nil
    replacementTask?.cancel()
    replacementTask = nil
    shown = nil
    overlay.copiedRecently = false
    overlay.replacedRecently = false
    return generation
  }

  private func finish(generation: Int, phase: OverlayState.Phase) {
    guard generation == self.generation else { return }
    overlay.copiedRecently = false
    overlay.replacedRecently = false
    overlay.phase = phase
    presenter.relayout(animated: false)
  }

  private func finishWithoutSelection(generation: Int) {
    guard boundaries.isTrusted() else {
      finish(
        generation: generation,
        phase: .error(
          message: "macOS has not granted Accessibility to this copy of Translate yet. Turn Translate off and on in Accessibility, then click Try again.",
          recovery: .openAccessibility
        )
      )
      watchAccessibilityGrant(generation: generation)
      return
    }
    finish(
      generation: generation,
      phase: .error(message: "No text selected. Highlight something, then press the shortcut again.", recovery: nil)
    )
  }

  private func watchAccessibilityGrant(generation: Int) {
    Task { [weak self] in
      for _ in 0..<60 {
        try? await Task.sleep(for: .milliseconds(500))
        guard let self, generation == self.generation else { return }
        if self.boundaries.isTrusted() {
          self.finish(
            generation: generation,
            phase: .error(message: "Accessibility is on. Select some text and press the shortcut again.", recovery: nil)
          )
          return
        }
      }
    }
  }

  static let captureFailedMessage = "Couldn't read the selection. Select the text and press the shortcut again."

  static let replaceFailedMessage = "Couldn't replace the selection. Copy the translation instead."

  static let tooLongMessage =
    "The selection is longer than 16,000 characters. Select less text and try again."

  static func message(for failure: ReplacementFailure) -> String {
    switch failure {
    case .appChanged:
      "Not replaced: the app with the selection is no longer in front. Copy the translation instead."
    case .selectionChanged:
      "Not replaced: the selection changed after it was translated. Select the text and translate again."
    }
  }
}
