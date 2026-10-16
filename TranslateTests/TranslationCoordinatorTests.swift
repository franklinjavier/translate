import Foundation
import Testing
@testable import Translate

/// Drives a coordinator through boundaries the test resumes by hand.
final class CoordinatorHarness {
  let overlay = OverlayState()
  let presenter = RecordingPresenter()
  var captures: [Pending<CaptureResult>] = []
  var translations: [(request: TranslationRequest, onPartial: @MainActor (String) -> Void, pending: Pending<String>)] = []
  var replacements: [(selection: CapturedSelection, translation: String, pending: Pending<ReplacementOutcome>)] = []
  var trusted = true
  var capturesHonorCancellation = true
  var translationsHonorCancellation = true
  lazy var coordinator = TranslationCoordinator(
    overlay: overlay,
    presenter: presenter,
    boundaries: SessionBoundaries(
      anchor: { .point(.zero) },
      isTrusted: { [weak self] in self?.trusted ?? true },
      capture: { [weak self] in
        guard let self else { throw CancellationError() }
        let pending = Pending<CaptureResult>(honorsCancellation: self.capturesHonorCancellation)
        self.captures.append(pending)
        return try await pending.wait()
      },
      translate: { [weak self] request, onPartial in
        guard let self else { throw CancellationError() }
        let pending = Pending<String>(honorsCancellation: self.translationsHonorCancellation)
        self.translations.append((request, onPartial, pending))
        return try await pending.wait()
      },
      replace: { [weak self] selection, translation in
        guard let self else { throw CancellationError() }
        let pending = Pending<ReplacementOutcome>()
        self.replacements.append((selection, translation, pending))
        return try await pending.wait()
      }
    )
  )

  static let english = TranslationTarget.english
  static let portuguese = TranslationTarget.portuguese
  static let claude = EngineConfiguration(engine: .claude, executableOverride: "", model: "sonnet")
  static let codex = EngineConfiguration(engine: .codex, executableOverride: "", model: "")

  /// Cancels what's in flight and releases boundaries that ignore cancellation.
  func tearDown() {
    coordinator.dismiss()
    for pending in captures where pending.isWaiting { pending.fail(CancellationError()) }
    for call in translations where call.pending.isWaiting { call.pending.fail(CancellationError()) }
    for call in replacements where call.pending.isWaiting { call.pending.fail(CancellationError()) }
  }

  func start(_ target: TranslationTarget = english, configuration: EngineConfiguration = claude) {
    coordinator.translate(to: target, configuration: configuration)
  }

  func selection(_ text: String) -> CaptureResult {
    .selection(CapturedSelection(text: text, source: .clipboard, appPID: 42, element: nil, range: nil, value: nil))
  }

  /// Starts a translation and walks it to a finished result.
  func finishedResult(source: String = "oi", translation: String = "hi") async throws {
    start()
    try await eventually { captures.count == 1 && captures[0].isWaiting }
    captures[0].resume(selection(source))
    try await eventually { translations.count == 1 }
    translations[0].pending.resume(translation)
    try await eventually { overlay.currentTranslation() == translation }
  }
}

struct TranslationCoordinatorTests {
  let harness = CoordinatorHarness()

  @Test func capturedTextIsTranslatedWithTheRequestedTargetAndConfiguration() async throws {
    defer { harness.tearDown() }
    harness.start(CoordinatorHarness.portuguese, configuration: CoordinatorHarness.codex)
    #expect(harness.presenter.presented == 1)
    try await eventually { harness.captures.count == 1 }
    harness.captures[0].resume(harness.selection("hello"))
    try await eventually { harness.translations.count == 1 }
    let request = harness.translations[0].request
    #expect(request.target == CoordinatorHarness.portuguese)
    #expect(request.configuration == CoordinatorHarness.codex)
    #expect(request.selection.text == "hello")
    #expect(harness.overlay.phase == .loading(target: CoordinatorHarness.portuguese, source: "hello"))
  }

  /// A boundary that ignores cancellation still can't land its late capture.
  @Test func supersededCaptureIsDropped() async throws {
    defer { harness.tearDown() }
    harness.capturesHonorCancellation = false
    harness.start(CoordinatorHarness.english)
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.start(CoordinatorHarness.portuguese)
    try await eventually { harness.captures.count == 2 && harness.captures[1].isWaiting }
    #expect(harness.captures[0].sawCancellation)

    harness.captures[0].resume(harness.selection("old"))
    harness.captures[1].resume(harness.selection("new"))
    try await eventually { harness.translations.count == 1 }
    try await Task.sleep(for: .milliseconds(10))
    #expect(harness.translations.count == 1)
    #expect(harness.translations[0].request.selection.text == "new")
    #expect(harness.translations[0].request.target == CoordinatorHarness.portuguese)
  }

  @Test func stalePartialAndFinalNeverReachTheNewTranslation() async throws {
    defer { harness.tearDown() }
    harness.translationsHonorCancellation = false
    harness.start(CoordinatorHarness.english)
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.captures[0].resume(harness.selection("first"))
    try await eventually { harness.translations.count == 1 }
    let stale = harness.translations[0]
    stale.onPartial("first partial")
    #expect(harness.overlay.currentTranslation() == "first partial")

    harness.start(CoordinatorHarness.portuguese)
    try await eventually { harness.captures.count == 2 && harness.captures[1].isWaiting }
    harness.captures[1].resume(harness.selection("second"))
    try await eventually { harness.translations.count == 2 }
    #expect(stale.pending.sawCancellation)

    stale.onPartial("stale partial")
    stale.pending.resume("stale final")
    try await Task.sleep(for: .milliseconds(10))
    #expect(harness.overlay.phase == .loading(target: CoordinatorHarness.portuguese, source: "second"))

    harness.translations[1].onPartial("segundo")
    #expect(harness.overlay.currentTranslation() == "segundo")
    harness.translations[1].pending.resume("segundo!")
    try await eventually { harness.overlay.phase == .result(target: CoordinatorHarness.portuguese, source: "second", translation: "segundo!") }
  }

  @Test func dismissCancelsTheTranslationAndHides() async throws {
    defer { harness.tearDown() }
    harness.start()
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.captures[0].resume(harness.selection("text"))
    try await eventually { harness.translations.count == 1 }
    harness.coordinator.dismiss()
    try await eventually { harness.translations[0].pending.sawCancellation }
    #expect(harness.overlay.phase == .hidden)
    #expect(harness.presenter.hidden == 1)
    harness.translations[0].onPartial("late")
    #expect(harness.overlay.phase == .hidden)
  }

  @Test func retryReusesTheCapturedTextWithFreshSettings() async throws {
    defer { harness.tearDown() }
    harness.start(CoordinatorHarness.portuguese, configuration: CoordinatorHarness.claude)
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.captures[0].resume(harness.selection("captured once"))
    try await eventually { harness.translations.count == 1 }
    harness.translations[0].pending.fail(TranslatorError.emptyResponse)
    try await eventually {
      if case .error = harness.overlay.phase { return true }
      return false
    }

    harness.coordinator.retry(configuration: CoordinatorHarness.codex)
    try await eventually { harness.translations.count == 2 }
    #expect(harness.captures.count == 1)
    let retried = harness.translations[1].request
    #expect(retried.selection.text == "captured once")
    #expect(retried.target == CoordinatorHarness.portuguese)
    #expect(retried.configuration == CoordinatorHarness.codex)
  }

  @Test func retryCapturesAgainWhenNothingWasCaptured() async throws {
    defer { harness.tearDown() }
    harness.trusted = false
    harness.start()
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.captures[0].resume(.empty)
    try await eventually {
      if case .error(_, .openAccessibility) = harness.overlay.phase { return true }
      return false
    }
    harness.trusted = true
    harness.coordinator.retry(configuration: CoordinatorHarness.claude)
    try await eventually { harness.captures.count == 2 }
  }

  @Test func tooLongSelectionIsNeverTranslated() async throws {
    defer { harness.tearDown() }
    harness.start()
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.captures[0].resume(.tooLong)
    try await eventually { harness.overlay.phase == .error(message: TranslationCoordinator.tooLongMessage, recovery: nil) }
    #expect(harness.translations.isEmpty)
  }

  @Test func replaceRunsOnceWithTheShownSelection() async throws {
    defer { harness.tearDown() }
    try await harness.finishedResult(source: "oi", translation: "hi")
    harness.coordinator.replace()
    harness.coordinator.replace()
    try await eventually { harness.replacements.count == 1 }
    try await Task.sleep(for: .milliseconds(5))
    #expect(harness.replacements.count == 1)
    #expect(harness.replacements[0].selection.text == "oi")
    #expect(harness.replacements[0].translation == "hi")

    harness.replacements[0].pending.resume(.verified)
    try await eventually { harness.overlay.phase == .hidden }
  }

  @Test func replaceWaitsForTheFinalTranslation() async throws {
    defer { harness.tearDown() }
    harness.start()
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }
    harness.captures[0].resume(harness.selection("oi"))
    try await eventually { harness.translations.count == 1 }
    harness.translations[0].onPartial("h")
    harness.coordinator.replace()
    try await Task.sleep(for: .milliseconds(5))
    #expect(harness.replacements.isEmpty)
  }

  @Test func refusedReplacementExplainsWhy() async throws {
    defer { harness.tearDown() }
    try await harness.finishedResult()
    harness.coordinator.replace()
    try await eventually { harness.replacements.count == 1 }
    harness.replacements[0].pending.resume(.failed(.selectionChanged))
    try await eventually {
      harness.overlay.phase == .error(message: TranslationCoordinator.message(for: .selectionChanged), recovery: nil)
    }
  }

  @Test func newTranslationCancelsAPendingReplacement() async throws {
    defer { harness.tearDown() }
    try await harness.finishedResult()
    harness.coordinator.replace()
    try await eventually { harness.replacements.count == 1 }
    harness.start(CoordinatorHarness.portuguese)
    try await eventually { harness.replacements[0].pending.sawCancellation }
    #expect(harness.overlay.phase == .loading(target: CoordinatorHarness.portuguese, source: ""))
  }
}

struct AppModelRequestTests {
  /// Engine settings are read when the shortcut is pressed, not after the capture returns.
  @Test func engineConfigurationIsSnapshotAtTheShortcut() async throws {
    var settings = AppSettings.default
    settings.engine = .claude
    settings.claudeModel = "sonnet"
    let harness = CoordinatorHarness()
    let model = AppModel(settings: settings, isLive: false, coordinator: harness.coordinator)
    defer { harness.tearDown() }
    model.translate(to: .english)
    try await eventually { harness.captures.count == 1 && harness.captures[0].isWaiting }

    model.settings.engine = .codex
    model.settings.claudeModel = "opus"
    harness.captures[0].resume(harness.selection("text"))
    try await eventually { harness.translations.count == 1 }
    #expect(harness.translations[0].request.configuration == EngineConfiguration(
      engine: .claude, executableOverride: "", model: "sonnet"
    ))
  }
}
