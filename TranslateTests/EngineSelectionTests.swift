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

  // MARK: Fast

  @Test func settingsSavedBeforeFastDecodeWithFastOff() throws {
    let settings = try decode(#"{"engine":"claude","claudeModel":"opus","codexModel":"gpt-6-sol"}"#)
    #expect(!settings.claudeFast)
    #expect(!settings.codexFast)
    #expect(settings.claudeModel == "opus")
    #expect(settings.codexModel == "gpt-6-sol")
    #expect(!AppSettings.default.claudeFast)
    #expect(!AppSettings.default.codexFast)
  }

  @Test(arguments: [(true, false), (false, true), (true, true)])
  func fastPreferencesAreIndependentAndRoundTrip(claude: Bool, codex: Bool) throws {
    var settings = AppSettings.default
    settings.claudeFast = claude
    settings.codexFast = codex
    let data = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["claudeFast"] as? Bool == claude)
    #expect(object["codexFast"] as? Bool == codex)
    #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
  }

  /// Claude asks for Fast only when its metadata lists the model as capable; Codex carries
  /// the preference and checks it against the catalog it runs with.
  @Test func configurationCarriesOnlyTheSelectedEnginesFast() {
    var settings = AppSettings.default
    settings.claudeFast = true
    settings.codexFast = false
    settings.claudeModel = "opus"
    settings.engine = .claude
    #expect(settings.engineConfiguration.fastMode == false, "unknown capability never asks for Fast")
    #expect(settings.engineConfiguration(claudeFastCapable: true).fastMode)
    #expect(settings.engineConfiguration(claudeFastCapable: true).model == "opus")
    settings.engine = .codex
    #expect(!settings.engineConfiguration(claudeFastCapable: true).fastMode)
    settings.codexFast = true
    #expect(settings.engineConfiguration.fastMode)
    settings.claudeFast = false
    settings.engine = .claude
    #expect(!settings.engineConfiguration(claudeFastCapable: true).fastMode)
    for engine in [TranslationEngine.local, .apple] {
      settings.engine = engine
      #expect(!settings.engineConfiguration(claudeFastCapable: true).fastMode)
    }
  }
}
