import Foundation
import Testing
@testable import Translate

struct EngineSelectionTests {
  private func decode(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
  }

  // MARK: Settings saved before `engine` existed

  @Test func legacyBackendBecomesTheEngine() throws {
    let settings = try decode("""
      {
        "backend": "claude",
        "claudePath": "",
        "claudeModel": "sonnet",
        "codexPath": "",
        "codexModel": "",
        "targets": [
          {"id": "00000000-0000-0000-0000-000000000001", "label": "English", "language": "english"},
          {"id": "00000000-0000-0000-0000-000000000002", "label": "Portuguese", "language": "Brazilian Portuguese"}
        ],
        "launchAtLogin": false
      }
      """)
    #expect(settings.engine == .claude)
    #expect(settings.claudeModel == "sonnet")
    #expect(settings.targets.count == 2)
  }

  @Test func legacyLocalBackendDecodes() throws {
    let settings = try decode(#"{"backend":"local","targets":[],"launchAtLogin":false}"#)
    #expect(settings.engine == .local)
  }

  /// The old Apple flag overrode a saved backend; leaving Apple restored that backend.
  @Test(arguments: [TranslationEngine.local, .claude, .codex])
  func legacyAppleFlagKeepsTheBackendToRestore(backend: TranslationEngine) throws {
    var settings = try decode(#"{"backend":"\#(backend.rawValue)","useAppleOnDeviceModel":true}"#)
    #expect(settings.engine == .apple)
    #expect(settings.previousEngine == backend)
    settings.toggleApple()
    #expect(settings.engine == backend)
  }

  @Test func legacyWithoutBackendDefaultsToClaudeAsBefore() throws {
    #expect(try decode("{}").engine == .claude)
    #expect(try decode(#"{"backend":"something-new"}"#).engine == .claude)
  }

  // MARK: Current format

  @Test func savesOneEngineAndRoundTrips() throws {
    var settings = AppSettings.default
    settings.engine = .codex
    settings.engine = .apple
    let data = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["engine"] as? String == "apple")
    #expect(object["previousEngine"] as? String == "codex")
    #expect(object["backend"] == nil)
    #expect(object["useAppleOnDeviceModel"] == nil)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded == settings)
  }

  @Test func previousEngineIsNeverApple() throws {
    let settings = try decode(#"{"engine":"apple","previousEngine":"apple"}"#)
    #expect(settings.previousEngine == .local)
  }

  // MARK: Selection

  @Test(arguments: [TranslationEngine.local, .claude, .codex])
  func appleToggleRestoresTheEngineChosenBefore(previous: TranslationEngine) {
    var settings = AppSettings.default
    settings.engine = previous
    settings.toggleApple()
    #expect(settings.engine == .apple)
    settings.toggleApple()
    #expect(settings.engine == previous)
  }

  @Test func choosingAnEngineWhileAppleIsOnBecomesTheOneToRestore() {
    var settings = AppSettings.default
    settings.engine = .apple
    settings.engine = .codex
    settings.engine = .apple
    settings.toggleApple()
    #expect(settings.engine == .codex)
  }

  @Test func eachEngineUsesOnlyItsOwnModelAndPath() {
    var settings = AppSettings.default
    settings.claudeModel = "opus"
    settings.claudePath = "/opt/claude"
    settings.codexModel = "gpt"
    settings.codexPath = "/opt/codex"

    settings.engine = .claude
    #expect(settings.engineConfiguration == EngineConfiguration(engine: .claude, executableOverride: "/opt/claude", model: "opus"))
    settings.engine = .codex
    #expect(settings.engineConfiguration == EngineConfiguration(engine: .codex, executableOverride: "/opt/codex", model: "gpt"))
    settings.engine = .local
    #expect(settings.engineConfiguration == EngineConfiguration(engine: .local, executableOverride: "", model: LocalMLX.defaultModel))
    settings.engine = .apple
    #expect(settings.engineConfiguration == EngineConfiguration(engine: .apple, executableOverride: "", model: ""))
  }
}
