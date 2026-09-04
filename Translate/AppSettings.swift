import Foundation
import KeyboardShortcuts

nonisolated enum LLMBackend: String, Codable, CaseIterable, Identifiable, Sendable {
  case local
  case claude
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .local: "Local"
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }

  var defaultExecutableName: String {
    switch self {
    case .local: ""
    case .claude: "claude"
    case .codex: "codex"
    }
  }
}

struct TranslationTarget: Codable, Equatable, Identifiable, Hashable {
  var id: UUID
  var label: String
  var language: String

  var shortcutName: KeyboardShortcuts.Name {
    KeyboardShortcuts.Name("translate.\(id.uuidString)")
  }

  static let englishID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  static let portugueseID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  static let english = TranslationTarget(
    id: englishID,
    label: "English",
    language: "english"
  )

  static let portuguese = TranslationTarget(
    id: portugueseID,
    label: "Portuguese",
    language: "Brazilian Portuguese"
  )
}

struct AppSettings: Codable, Equatable {
  var backend: LLMBackend
  var claudePath: String
  var claudeModel: String
  var codexPath: String
  var codexModel: String
  var targets: [TranslationTarget]
  var launchAtLogin: Bool
  var useAppleOnDeviceModel: Bool

  static let defaultsKey = "appSettings"

  static let `default` = AppSettings(
    backend: .local,
    claudePath: "",
    claudeModel: "",
    codexPath: "",
    codexModel: "",
    targets: [.english, .portuguese],
    launchAtLogin: false,
    useAppleOnDeviceModel: false
  )

  init(
    backend: LLMBackend,
    claudePath: String,
    claudeModel: String,
    codexPath: String,
    codexModel: String,
    targets: [TranslationTarget],
    launchAtLogin: Bool,
    useAppleOnDeviceModel: Bool
  ) {
    self.backend = backend
    self.claudePath = claudePath
    self.claudeModel = claudeModel
    self.codexPath = codexPath
    self.codexModel = codexModel
    self.targets = targets
    self.launchAtLogin = launchAtLogin
    self.useAppleOnDeviceModel = useAppleOnDeviceModel
  }

  enum CodingKeys: String, CodingKey {
    case backend, claudePath, claudeModel, codexPath, codexModel
    case targets, launchAtLogin, useAppleOnDeviceModel
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    backend = try container.decodeIfPresent(LLMBackend.self, forKey: .backend) ?? .claude
    claudePath = try container.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
    claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? ""
    codexPath = try container.decodeIfPresent(String.self, forKey: .codexPath) ?? ""
    codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel) ?? ""
    targets = try container.decodeIfPresent([TranslationTarget].self, forKey: .targets)
      ?? [.english, .portuguese]
    launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    useAppleOnDeviceModel = try container.decodeIfPresent(Bool.self, forKey: .useAppleOnDeviceModel)
      ?? false
  }

  var activeExecutableOverride: String {
    switch backend {
    case .local: ""
    case .claude: claudePath
    case .codex: codexPath
    }
  }

  var activeModel: String {
    switch backend {
    case .local: LocalMLX.defaultModel
    case .claude: claudeModel
    case .codex: codexModel
    }
  }

  func save() {
    guard let data = try? JSONEncoder().encode(self) else { return }
    UserDefaults.standard.set(data, forKey: Self.defaultsKey)
  }

  static func load() -> AppSettings {
    guard
      let data = UserDefaults.standard.data(forKey: defaultsKey),
      var settings = try? JSONDecoder().decode(AppSettings.self, from: data)
    else {
      return .default
    }
    if UserDefaults.standard.object(forKey: "didSelectLocalEngine") == nil {
      settings.backend = .local
      settings.useAppleOnDeviceModel = false
      settings.save()
      UserDefaults.standard.set(true, forKey: "didSelectLocalEngine")
    }
    return settings
  }
}
