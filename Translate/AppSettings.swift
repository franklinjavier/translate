import Foundation
import KeyboardShortcuts

/// The one engine translations run on. Saved as `engine`; older settings stored a CLI
/// backend plus an Apple flag that overrode it, and decode into this.
nonisolated enum TranslationEngine: String, Codable, CaseIterable, Identifiable, Sendable {
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

  /// The CLI's name on PATH, for the engines that run one.
  var executableName: String {
    switch self {
    case .local, .apple: ""
    case .claude: "claude"
    case .codex: "codex"
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
  var engine: TranslationEngine {
    didSet {
      if engine != .apple { previousEngine = engine }
    }
  }
  /// The last engine other than Apple, restored when the menu turns Apple Translate off.
  private(set) var previousEngine: TranslationEngine
  var claudePath: String
  var claudeModel: String
  var codexPath: String
  var codexModel: String
  var targets: [TranslationTarget]
  var launchAtLogin: Bool

  static let defaultsKey = "appSettings"

  static let `default` = AppSettings(
    engine: .local,
    claudePath: "",
    claudeModel: "",
    codexPath: "",
    codexModel: "",
    targets: [.english, .portuguese],
    launchAtLogin: false
  )

  init(
    engine: TranslationEngine,
    previousEngine: TranslationEngine = .local,
    claudePath: String,
    claudeModel: String,
    codexPath: String,
    codexModel: String,
    targets: [TranslationTarget],
    launchAtLogin: Bool
  ) {
    self.engine = engine
    self.previousEngine = engine == .apple ? Self.restorable(previousEngine) : engine
    self.claudePath = claudePath
    self.claudeModel = claudeModel
    self.codexPath = codexPath
    self.codexModel = codexModel
    self.targets = targets
    self.launchAtLogin = launchAtLogin
  }

  enum CodingKeys: String, CodingKey {
    case engine, previousEngine, claudePath, claudeModel, codexPath, codexModel
    case targets, launchAtLogin
    /// Read from settings saved before `engine` existed; never written.
    case backend, useAppleOnDeviceModel
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let engine = try container.decodeIfPresent(TranslationEngine.self, forKey: .engine) {
      self.engine = engine
      let previous = try container.decodeIfPresent(TranslationEngine.self, forKey: .previousEngine)
      previousEngine = engine == .apple ? Self.restorable(previous ?? .local) : engine
    } else {
      // Legacy: a CLI backend (Claude when missing) that the Apple flag overrode while on.
      let backend = try container.decodeIfPresent(String.self, forKey: .backend)
        .flatMap(TranslationEngine.init(rawValue:)) ?? .claude
      let apple = try container.decodeIfPresent(Bool.self, forKey: .useAppleOnDeviceModel) ?? false
      engine = apple ? .apple : Self.restorable(backend)
      previousEngine = Self.restorable(backend)
    }
    claudePath = try container.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
    claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? ""
    codexPath = try container.decodeIfPresent(String.self, forKey: .codexPath) ?? ""
    codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel) ?? ""
    targets = try container.decodeIfPresent([TranslationTarget].self, forKey: .targets)
      ?? [.english, .portuguese]
    launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(engine, forKey: .engine)
    try container.encode(previousEngine, forKey: .previousEngine)
    try container.encode(claudePath, forKey: .claudePath)
    try container.encode(claudeModel, forKey: .claudeModel)
    try container.encode(codexPath, forKey: .codexPath)
    try container.encode(codexModel, forKey: .codexModel)
    try container.encode(targets, forKey: .targets)
    try container.encode(launchAtLogin, forKey: .launchAtLogin)
  }

  private static func restorable(_ engine: TranslationEngine) -> TranslationEngine {
    engine == .apple ? .local : engine
  }

  /// The menu's Apple toggle: on, or back to the engine used before it.
  mutating func toggleApple() {
    engine = engine == .apple ? previousEngine : .apple
  }

  /// What a translation started now would run with.
  var engineConfiguration: EngineConfiguration {
    switch engine {
    case .local: EngineConfiguration(engine: .local, executableOverride: "", model: LocalMLX.defaultModel)
    case .apple: EngineConfiguration(engine: .apple, executableOverride: "", model: "")
    case .claude: EngineConfiguration(engine: .claude, executableOverride: claudePath, model: claudeModel)
    case .codex: EngineConfiguration(engine: .codex, executableOverride: codexPath, model: codexModel)
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
      settings.engine = .local
      settings.save()
      UserDefaults.standard.set(true, forKey: "didSelectLocalEngine")
    }
    return settings
  }
}
