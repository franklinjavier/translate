import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Translate

private func makeTargets(_ count: Int) -> [TranslationTarget] {
  (0..<count).map { TranslationTarget(id: UUID(), label: "Label \($0)", language: "Language \($0)") }
}

private func makeSettings(_ targets: [TranslationTarget], backend: LLMBackend = .local) -> AppSettings {
  var settings = AppSettings.default
  settings.targets = targets
  settings.backend = backend
  return settings
}

struct TargetSettingsTests {
  @Test(arguments: [0, 2, 4])
  func removesFirstMiddleAndLastByID(index: Int) {
    let targets = makeTargets(5)
    var settings = makeSettings(targets)
    let removed = settings.removeTarget(id: targets[index].id)
    #expect(removed == targets[index])
    var expected = targets
    expected.remove(at: index)
    #expect(settings.targets == expected)
  }

  @Test func removingUnknownIDChangesNothing() {
    let targets = makeTargets(3)
    var settings = makeSettings(targets)
    #expect(settings.removeTarget(id: UUID()) == nil)
    #expect(settings.targets == targets)
  }

  @Test func lastLanguageCannotBeRemoved() {
    let targets = makeTargets(1)
    var settings = makeSettings(targets)
    #expect(!settings.canRemoveTarget)
    #expect(settings.removeTarget(id: targets[0].id) == nil)
    #expect(settings.targets == targets)
  }

  /// The key path SwiftUI holds for a row. An index-based one traps here (Array._checkSubscript).
  @Test func staleRowKeyPathReadsItsSnapshotAndDropsWrites() {
    let targets = makeTargets(3)
    var settings = makeSettings(targets)
    let stale = \AppSettings.[targetID: targets[2].id, fallback: targets[2]]
    _ = settings.removeTarget(id: targets[2].id)

    #expect(settings[keyPath: stale] == targets[2])
    settings[keyPath: stale.appending(path: \.label)] = "Ghost"
    #expect(settings.targets == Array(targets.prefix(2)))
  }

  @Test func rowWritesFollowTheIDAfterAnEarlierRowIsRemoved() {
    let targets = makeTargets(3)
    var settings = makeSettings(targets)
    let last = \AppSettings.[targetID: targets[2].id, fallback: targets[2]].language
    _ = settings.removeTarget(id: targets[0].id)

    settings[keyPath: last] = "Japanese"
    #expect(settings.targets.map(\.language) == ["Language 1", "Japanese"])
  }

  @Test func updateKeepsTheRowID() {
    let targets = makeTargets(2)
    var settings = makeSettings(targets)
    var replacement = targets[1]
    replacement.id = UUID()
    replacement.label = "Renamed"
    let updated = settings.updateTarget(id: targets[1].id, to: replacement)
    #expect(updated)
    #expect(settings.targets[1].id == targets[1].id)
    #expect(settings.targets[1].label == "Renamed")
    let updatedMissing = settings.updateTarget(id: UUID(), to: replacement)
    #expect(!updatedMissing)
  }
}

struct TranslationLanguageTests {
  @Test func catalogTargetsAndNamesAreUnique() {
    let catalog = TranslationLanguage.catalog
    #expect((20...30).contains(catalog.count))
    #expect(Set(catalog.map(\.target)).count == catalog.count)
    #expect(Set(catalog.map(\.name)).count == catalog.count)
    #expect(Set(catalog.map(\.label)).count == catalog.count)
  }

  @Test func defaultRowsMatchCatalogEntriesExactly() {
    #expect(TranslationTarget.english.language == "english")
    #expect(TranslationTarget.english.label == "English")
    #expect(TranslationTarget.portuguese.language == "Brazilian Portuguese")
    #expect(TranslationTarget.portuguese.label == "Portuguese")
    #expect(TranslationLanguage.entry(for: "english") == .english)
    #expect(TranslationLanguage.entry(for: "Brazilian Portuguese") == .brazilianPortuguese)
    #expect(!TranslationTarget.english.isLegacyLanguage)
    #expect(!TranslationTarget.portuguese.isLegacyLanguage)
    #expect(AppSettings.default.targets == [.english, .portuguese])
  }

  @Test func catalogCoversTheCommonLanguages() {
    let targets = Set(TranslationLanguage.catalog.map(\.target))
    for expected in [
      "english", "Brazilian Portuguese", "European Portuguese", "Spanish", "French", "German",
      "Italian", "Japanese", "Simplified Chinese", "Traditional Chinese", "Korean", "Arabic",
    ] {
      #expect(targets.contains(expected), "\(expected)")
    }
  }

  @Test func legacyDestinationIsKeptAsWrittenAndRoundTrips() throws {
    let legacy = TranslationTarget(id: UUID(), label: "Pirate", language: "pirate english")
    let settings = makeSettings([legacy, .english])
    #expect(legacy.isLegacyLanguage)
    #expect(TranslationLanguage.entry(for: "English") == nil, "matching is exact; no silent rewrite")

    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.targets == settings.targets)

    // Loading and rebinding the row leaves the saved string alone.
    let model = AppModel(settings: decoded, isLive: false)
    let binding = model.targetBinding(for: legacy)
    #expect(binding.wrappedValue.language == "pirate english")
    #expect(model.settings.targets == [legacy, .english])
  }

  @Test func customLabelSurvivesDestinationChanges() {
    var target = TranslationTarget(id: UUID(), label: "Work", language: "english")
    target.setDestination(.brazilianPortuguese)
    #expect(target.label == "Work")
    #expect(target.language == "Brazilian Portuguese")

    var legacy = TranslationTarget(id: UUID(), label: "Pirate", language: "pirate english")
    legacy.setDestination(.english)
    #expect(legacy.label == "Pirate")
    #expect(legacy.language == "english")
  }

  @Test func generatedAndPlaceholderLabelsFollowTheDestination() {
    var portuguese = TranslationTarget.portuguese
    portuguese.setDestination(TranslationLanguage.entry(for: "European Portuguese")!)
    #expect(portuguese.label == "Portuguese (Portugal)")
    #expect(portuguese.id == TranslationTarget.portugueseID)

    var placeholder = TranslationTarget(id: UUID(), label: "New language", language: "French")
    placeholder.setDestination(TranslationLanguage.entry(for: "Korean")!)
    #expect(placeholder.label == "Korean")
    #expect(placeholder.language == "Korean")
  }
}

/// `isLive: false` keeps these off the user's saved settings, global shortcuts and login items.
struct AppModelTargetTests {
  @Test func staleBindingAfterRemoveNeitherCrashesNorTouchesAnotherRow() {
    let targets = makeTargets(3)
    let model = AppModel(settings: makeSettings(targets), isLive: false)
    let bindings = model.settings.targets.map(model.targetBinding(for:))

    model.removeTarget(id: targets[1].id)

    let stale = bindings[1]
    #expect(stale.wrappedValue == targets[1])
    stale.wrappedValue.label = "Ghost"
    stale.wrappedValue.language = "Ghost"
    #expect(model.settings.targets == [targets[0], targets[2]])

    // The last row moved from index 2 to 1; its binding still finds it.
    let moved = bindings[2]
    moved.wrappedValue.label = "Still here"
    #expect(model.settings.targets.map(\.label) == ["Label 0", "Still here"])
  }

  @Test func removesRowsFromEveryPositionDownToTheLastOne() {
    let targets = makeTargets(4)
    let model = AppModel(settings: makeSettings(targets), isLive: false)

    model.removeTarget(id: targets[1].id) // middle
    model.removeTarget(id: targets[3].id) // last
    model.removeTarget(id: targets[0].id) // first
    #expect(model.settings.targets == [targets[2]])

    model.removeTarget(id: targets[2].id) // the only one left stays
    model.removeTarget(id: targets[0].id) // already gone
    #expect(model.settings.targets == [targets[2]])
  }

  @Test func addEditRemoveLifecycle() {
    let targets = makeTargets(1)
    let model = AppModel(settings: makeSettings(targets), isLive: false)

    let id = model.addTarget(TranslationLanguage.entry(for: "French")!)
    #expect(model.settings.targets.count == 2)
    #expect(model.settings.canRemoveTarget)

    let added = model.settings.target(withID: id)!
    let binding = model.targetBinding(for: added)
    binding.wrappedValue.label = "Japanese"
    binding.wrappedValue.language = "Japanese"
    #expect(model.settings.target(withID: id)?.language == "Japanese")
    #expect(model.settings.targets[0] == targets[0])

    model.removeTarget(id: id)
    #expect(model.settings.targets == targets)
    binding.wrappedValue.label = "Ghost"
    #expect(model.settings.targets == targets)
  }

  @Test func addsTheChosenLanguageWithItsLabelAndTarget() {
    let model = AppModel(settings: makeSettings(makeTargets(1)), isLive: false)
    let japanese = TranslationLanguage.entry(for: "Japanese")!

    let id = model.addTarget(japanese)
    let added = model.settings.target(withID: id)
    #expect(added?.label == "Japanese")
    #expect(added?.language == "Japanese")
    #expect(model.settings.targets.last?.id == id)
  }

  @Test func changingDestinationKeepsIDAndShortcut() {
    let targets = makeTargets(2)
    let model = AppModel(settings: makeSettings(targets), isLive: false)
    let id = model.addTarget(.english)
    let shortcut = model.settings.target(withID: id)!.shortcutName.rawValue
    let binding = model.targetBinding(for: model.settings.target(withID: id)!)

    binding.wrappedValue.setDestination(TranslationLanguage.entry(for: "German")!)

    let changed = model.settings.target(withID: id)!
    #expect(changed.id == id)
    #expect(changed.shortcutName.rawValue == shortcut)
    #expect(changed.language == "German")
    #expect(changed.label == "German")
    #expect(Array(model.settings.targets.prefix(2)) == targets)
  }

  @Test func eachBackendUsesOnlyItsOwnModelAndPath() {
    var settings = makeSettings(makeTargets(1))
    settings.claudeModel = "opus"
    settings.claudePath = "/opt/claude"
    settings.codexModel = "gpt"
    settings.codexPath = "/opt/codex"

    settings.backend = .claude
    #expect(settings.activeModel == "opus")
    #expect(settings.activeExecutableOverride == "/opt/claude")
    settings.backend = .codex
    #expect(settings.activeModel == "gpt")
    #expect(settings.activeExecutableOverride == "/opt/codex")
    settings.backend = .local
    #expect(settings.activeExecutableOverride.isEmpty)
  }
}

struct EngineSelectionTests {
  @Test func legacyFlagsProjectToOneEngine() {
    var settings = makeSettings(makeTargets(1), backend: .codex)
    #expect(settings.engine == .codex)
    settings.useAppleOnDeviceModel = true
    #expect(settings.engine == .apple, "the Apple flag wins over any saved backend")
  }

  @Test(arguments: [LLMBackend.local, .claude, .codex])
  func choosingAppleKeepsTheBackendForLeavingIt(previous: LLMBackend) {
    var settings = makeSettings(makeTargets(1), backend: previous)
    settings.engine = .apple
    #expect(settings.useAppleOnDeviceModel)
    #expect(settings.backend == previous)
    #expect(settings.engine == .apple)
  }

  @Test(arguments: [TranslationEngine.local, .claude, .codex])
  func choosingAnOrdinaryEngineClearsAppleAndSetsTheBackend(engine: TranslationEngine) {
    var settings = makeSettings(makeTargets(1), backend: .local)
    settings.useAppleOnDeviceModel = true
    settings.engine = engine
    #expect(!settings.useAppleOnDeviceModel)
    #expect(settings.backend == engine.backend)
    #expect(settings.engine == engine)
  }

  @Test func savedFormatIsUnchanged() throws {
    var settings = makeSettings(makeTargets(1), backend: .claude)
    settings.engine = .apple
    let data = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["engine"] == nil)
    #expect(object["backend"] as? String == "claude")
    #expect(object["useAppleOnDeviceModel"] as? Bool == true)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.engine == .apple)
    #expect(decoded.backend == .claude)
  }
}

struct AppleEngineTests {
  /// The Claude path doesn't exist, so a fallback would fail as executableNotFound (or spawn
  /// whatever `claude` is on PATH). Apple must stop first, with its own error.
  @Test func sameLanguageFailsWithoutFallingBackToACLI() async throws {
    let translator = Translator(
      backend: .claude,
      executableOverride: "/nonexistent/translate-tests/claude",
      model: "",
      useAppleOnDeviceModel: true
    )
    do {
      _ = try await translator.translate(
        text: "This sentence is already written in plain English and only needs a proofread.",
        targetLanguage: "english",
        onOutput: { _ in },
        onPartial: { _ in }
      )
      Issue.record("expected appleUnavailable")
    } catch TranslatorError.appleUnavailable(let message) {
      #expect(message == AppleTranslation.cannotProofreadMessage)
    }
  }

  @Test func everyCatalogDestinationMapsToALocaleIdentifier() throws {
    for language in TranslationLanguage.catalog {
      let mapped = try #require(AppleLanguageMapper.language(from: language.target), "\(language.target)")
      let code = try #require(mapped.languageCode?.identifier, "\(language.target)")
      #expect((2...3).contains(code.count), "\(language.target) → \(code)")
    }
    #expect(AppleLanguageMapper.language(from: "European Portuguese")?.region?.identifier == "PT")
    #expect(AppleLanguageMapper.language(from: "Brazilian Portuguese")?.region?.identifier == "BR")
    #expect(AppleLanguageMapper.language(from: "Simplified Chinese")?.script?.identifier == "Hans")
    #expect(AppleLanguageMapper.language(from: "Traditional Chinese")?.script?.identifier == "Hant")
  }
}

/// The appearance a snapshot is forced into, independent of the system setting.
nonisolated enum SnapshotAppearance: String, CaseIterable, Sendable {
  case light
  case dark

  var name: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
  /// The pure background the settings screen should paint in this appearance.
  var backgroundWhite: CGFloat { self == .dark ? 0 : 1 }
}

/// Renders the settings screen into a PNG without ordering a window on screen, so nothing takes
/// focus. Each engine renders in light and dark, written as settings-<engine>-<appearance>.png.
/// The path is printed; set SETTINGS_SNAPSHOT_DIR (TEST_RUNNER_SETTINGS_SNAPSHOT_DIR under
/// xcodebuild) to write somewhere other than the temporary directory.
struct SettingsSnapshotTests {
  @Test(arguments: TranslationEngine.allCases, SnapshotAppearance.allCases)
  func rendersOffscreen(engine: TranslationEngine, appearance: SnapshotAppearance) async throws {
    var settings = makeSettings(makeTargets(4))
    settings.engine = engine
    let model = AppModel(settings: settings, isLive: false)
    let view = NSHostingView(rootView: SettingsView(model: model))
    let window = NSWindow(
      contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: SettingsView.size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: appearance.name)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    view.layoutSubtreeIfNeeded()

    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    #expect(rep.size == SettingsView.size)

    // Corners sit outside every section, so they show the bare background.
    let corners = [(1, 1), (rep.pixelsWide - 2, 1), (1, rep.pixelsHigh - 2), (rep.pixelsWide - 2, rep.pixelsHigh - 2)]
    for (x, y) in corners {
      let pixel = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      for component in [pixel.redComponent, pixel.greenComponent, pixel.blueComponent] {
        #expect(abs(component - appearance.backgroundWhite) < 0.02, "pixel (\(x), \(y)) is \(pixel)")
      }
    }

    let directory = ProcessInfo.processInfo.environment["SETTINGS_SNAPSHOT_DIR"]
      .map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory.appending(path: "TranslateSnapshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "settings-\(engine.rawValue)-\(appearance.rawValue).png")
    try png.write(to: url)
    print("Settings snapshot: \(url.path)")
  }
}
