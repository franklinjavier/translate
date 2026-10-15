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

/// What the settings picker shows. Not saved itself: it projects `backend` and
/// `useAppleOnDeviceModel`, so the stored format stays as it was.
nonisolated enum TranslationEngine: String, CaseIterable, Identifiable, Sendable {
  case local
  case apple
  case claude
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .local: "Local"
    case .apple: "Apple"
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }

  var backend: LLMBackend? {
    switch self {
    case .local: .local
    case .apple: nil
    case .claude: .claude
    case .codex: .codex
    }
  }
}

/// A destination the settings picker offers. `target` is the string saved in
/// `TranslationTarget.language` and sent to the translator; `label` names a new row.
nonisolated struct TranslationLanguage: Identifiable, Hashable, Sendable {
  var name: String
  var target: String
  var label: String

  var id: String { target }

  init(_ name: String, target: String, label: String? = nil) {
    self.name = name
    self.target = target
    self.label = label ?? name
  }

  /// Match the built-in English and Portuguese rows exactly, so they pick these entries.
  static let english = TranslationLanguage("English", target: "english")
  static let brazilianPortuguese = TranslationLanguage(
    "Portuguese (Brazil)",
    target: "Brazilian Portuguese",
    label: "Portuguese"
  )

  static let catalog: [TranslationLanguage] = [
    english,
    brazilianPortuguese,
    TranslationLanguage("Portuguese (Portugal)", target: "European Portuguese"),
    TranslationLanguage("Spanish", target: "Spanish"),
    TranslationLanguage("French", target: "French"),
    TranslationLanguage("German", target: "German"),
    TranslationLanguage("Italian", target: "Italian"),
    TranslationLanguage("Dutch", target: "Dutch"),
    TranslationLanguage("Swedish", target: "Swedish"),
    TranslationLanguage("Danish", target: "Danish"),
    TranslationLanguage("Norwegian", target: "Norwegian"),
    TranslationLanguage("Finnish", target: "Finnish"),
    TranslationLanguage("Polish", target: "Polish"),
    TranslationLanguage("Czech", target: "Czech"),
    TranslationLanguage("Ukrainian", target: "Ukrainian"),
    TranslationLanguage("Russian", target: "Russian"),
    TranslationLanguage("Greek", target: "Greek"),
    TranslationLanguage("Turkish", target: "Turkish"),
    TranslationLanguage("Arabic", target: "Arabic"),
    TranslationLanguage("Hebrew", target: "Hebrew"),
    TranslationLanguage("Hindi", target: "Hindi"),
    TranslationLanguage("Indonesian", target: "Indonesian"),
    TranslationLanguage("Vietnamese", target: "Vietnamese"),
    TranslationLanguage("Thai", target: "Thai"),
    TranslationLanguage("Japanese", target: "Japanese"),
    TranslationLanguage("Korean", target: "Korean"),
    TranslationLanguage("Chinese (Simplified)", target: "Simplified Chinese"),
    TranslationLanguage("Chinese (Traditional)", target: "Traditional Chinese"),
  ]

  /// Exact match only. Anything else is a legacy value the picker keeps as its own entry.
  static func entry(for target: String) -> TranslationLanguage? {
    catalog.first { $0.target == target }
  }
}

struct TranslationTarget: Codable, Equatable, Identifiable, Hashable {
  var id: UUID
  var label: String
  var language: String

  var shortcutName: KeyboardShortcuts.Name {
    KeyboardShortcuts.Name("translate.\(id.uuidString)")
  }

  /// The label rows used to get before the destination became a picker.
  static let placeholderLabel = "New language"

  /// True when `language` isn't in the catalog, e.g. text typed before the picker existed.
  var isLegacyLanguage: Bool { TranslationLanguage.entry(for: language) == nil }

  /// Keeps the ID, and so the shortcut. The label follows only while it's still the one the
  /// previous destination generated, or the old placeholder; a name the user typed stays.
  mutating func setDestination(_ destination: TranslationLanguage) {
    let generatedLabel = TranslationLanguage.entry(for: language)?.label
    if label == Self.placeholderLabel || label == generatedLabel {
      label = destination.label
    }
    language = destination.target
  }

  static let englishID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  static let portugueseID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  static let english = TranslationTarget(
    id: englishID,
    label: TranslationLanguage.english.label,
    language: TranslationLanguage.english.target
  )

  static let portuguese = TranslationTarget(
    id: portugueseID,
    label: TranslationLanguage.brazilianPortuguese.label,
    language: TranslationLanguage.brazilianPortuguese.target
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

  /// Apple wins while its flag is on. Choosing Apple leaves `backend` alone, so leaving Apple
  /// later can restore it; choosing any other engine turns the flag off and sets the backend.
  var engine: TranslationEngine {
    get {
      if useAppleOnDeviceModel { return .apple }
      switch backend {
      case .local: return .local
      case .claude: return .claude
      case .codex: return .codex
      }
    }
    set {
      if let backend = newValue.backend {
        self.backend = backend
        useAppleOnDeviceModel = false
      } else {
        useAppleOnDeviceModel = true
      }
    }
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

  var canRemoveTarget: Bool { targets.count > 1 }

  func target(withID id: UUID) -> TranslationTarget? {
    targets.first { $0.id == id }
  }

  /// Settings rows bind through this instead of an array index. Each read and write looks the ID
  /// up again, so a row SwiftUI is still tearing down after a removal reads its last snapshot and
  /// its writes are dropped, rather than trapping on a stale index or landing on a neighbor.
  subscript(targetID id: UUID, fallback fallback: TranslationTarget) -> TranslationTarget {
    get { target(withID: id) ?? fallback }
    set { updateTarget(id: id, to: newValue) }
  }

  /// False, and nothing changes, when no row has `id` any more.
  @discardableResult
  mutating func updateTarget(id: UUID, to value: TranslationTarget) -> Bool {
    guard let index = targets.firstIndex(where: { $0.id == id }) else { return false }
    var value = value
    value.id = id
    targets[index] = value
    return true
  }

  mutating func addTarget(_ language: TranslationLanguage) -> TranslationTarget {
    let target = TranslationTarget(id: UUID(), label: language.label, language: language.target)
    targets.append(target)
    return target
  }

  /// The removed row, or nil when `id` is unknown or it's the last language left.
  mutating func removeTarget(id: UUID) -> TranslationTarget? {
    guard canRemoveTarget, let index = targets.firstIndex(where: { $0.id == id }) else { return nil }
    return targets.remove(at: index)
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
