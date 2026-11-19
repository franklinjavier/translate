import Foundation
import Testing
@testable import Translate

nonisolated enum ModelFixtures {
  /// Claude's initialize response as the CLI prints it, with account and command data the
  /// app must not keep.
  static func claudeInitialize(models: String, requestID: String = "models-only", subtype: String = "success") -> String {
    let response = #"{"type":"control_response","response":{"subtype":"\#(subtype)","request_id":"\#(requestID)","response":{"account":{"email":"person@example.invalid","organization":"Private Org"},"commands":[{"name":"secret-command"}],"agents":["private-agent"],"fast_mode_state":"off","models":\#(models.replacingOccurrences(of: "\n", with: ""))}}}"#
    return #"{"type":"system","subtype":"hook_started"}"# + "\nnot json\n" + response + "\n"
  }

  static let claudeModels = """
    [{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","supportsFastMode":true},
     {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","supportsFastMode":true},
     {"value":"fable","resolvedModel":"claude-fable-5-2","displayName":"Fable 5.2","supportsFastMode":true},
     {"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5"},
     {"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5","supportsFastMode":false},
     {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Duplicate"},
     {"displayName":"No value"},
     {"value":"claude-opus-4-6","resolvedModel":"claude-opus-4-6","displayName":"Opus 4.6"}]
    """

  /// A refreshed Codex catalog: out of priority order, with hidden models and tiers.
  static let codexCatalog = """
    {"models":[
      {"slug":"gpt-astra","display_name":"GPT-Astra","visibility":"list","priority":2,
       "service_tiers":[{"id":"priority","name":"Fast"}],"base_instructions":"AGENT"},
      {"slug":"gpt-internal","display_name":"Internal","visibility":"hide","priority":0,
       "service_tiers":[{"id":"priority","name":"Fast"}],"base_instructions":"AGENT"},
      {"slug":"gpt-sol","display_name":"GPT-Sol","visibility":"list","priority":1,
       "service_tiers":[{"id":"priority","name":"Fast"},{"id":"ultrafast","name":"Ultrafast"}],
       "base_instructions":"AGENT"},
      {"slug":"gpt-plain","visibility":"list","priority":3,"service_tiers":[],
       "default_service_tier":"priority","base_instructions":"AGENT"},
      {"slug":"gpt-sol","display_name":"Duplicate","visibility":"list","priority":4,"base_instructions":"AGENT"}
    ]}
    """
}

struct CLIModelCatalogTests {
  @Test func claudeKeepsModelsAndFastOnlyAndMapsTheDefault() throws {
    let output = ModelFixtures.claudeInitialize(models: ModelFixtures.claudeModels)
    let catalog = try CLIModelCatalog.claude(fromInitializeOutput: Data(output.utf8))
    #expect(catalog.options == [
      CLIModelOption(id: "", name: "CLI default (Opus 5.5)"),
      CLIModelOption(id: "opus", name: "Opus 5.5"),
      CLIModelOption(id: "fable", name: "Fable 5.2"),
      CLIModelOption(id: "sonnet", name: "Sonnet 5.5"),
      CLIModelOption(id: "haiku", name: "Haiku 5.5"),
      CLIModelOption(id: "claude-opus-4-6", name: "Opus 4.6"),
    ])
    // The default's capability comes from the CLI's own default entry.
    #expect(catalog.supportsFast(""))
    #expect(catalog.supportsFast("opus"))
    #expect(catalog.supportsFast("claude-opus-5-5"), "a saved full ID resolves like its alias")
    #expect(catalog.supportsFast("fable"))
    #expect(!catalog.supportsFast("sonnet"), "missing supportsFastMode is no Fast")
    #expect(!catalog.supportsFast("haiku"))
    #expect(!catalog.supportsFast("claude-unknown"))
    let kept = String(describing: catalog)
    for privateValue in ["person@example.invalid", "Private Org", "secret-command", "private-agent"] {
      #expect(!kept.contains(privateValue))
    }
  }

  @Test func claudeDefaultWithoutFastIsStandard() throws {
    let models = #"[{"value":"default","resolvedModel":"claude-sonnet-5-5"},{"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5"},{"value":"opus","supportsFastMode":true}]"#
    let catalog = try CLIModelCatalog.claude(fromInitializeOutput: Data(ModelFixtures.claudeInitialize(models: models).utf8))
    #expect(catalog.options.first == CLIModelOption(id: "", name: "CLI default (Sonnet 5.5)"))
    #expect(!catalog.supportsFast(""))
    #expect(catalog.supportsFast("opus"))
  }

  @Test(arguments: [
    "",
    "not json\n",
    ModelFixtures.claudeInitialize(models: "[]"),
    ModelFixtures.claudeInitialize(models: #"[{"displayName":"no value"}]"#),
    ModelFixtures.claudeInitialize(models: ModelFixtures.claudeModels, requestID: "other"),
    ModelFixtures.claudeInitialize(models: ModelFixtures.claudeModels, subtype: "error"),
  ])
  func claudeRejectsMalformedMetadata(output: String) {
    #expect(throws: CLIModelError.unreadable) {
      _ = try CLIModelCatalog.claude(fromInitializeOutput: Data(output.utf8))
    }
  }

  @Test func codexListsVisibleModelsByPriorityWithTheirDefault() throws {
    let catalog = try CLIModelCatalog.codex(fromCatalog: Data(ModelFixtures.codexCatalog.utf8))
    #expect(catalog.options == [
      CLIModelOption(id: "", name: "CLI default (GPT-Sol)"),
      CLIModelOption(id: "gpt-sol", name: "GPT-Sol"),
      CLIModelOption(id: "gpt-astra", name: "GPT-Astra"),
      CLIModelOption(id: "gpt-plain", name: "gpt-plain"),
    ])
    #expect(catalog.supportsFast(""))
    #expect(catalog.supportsFast("gpt-sol"))
    #expect(catalog.supportsFast("gpt-astra"))
    #expect(catalog.supportsFast("gpt-internal"), "hidden, but a saved choice keeps its capability")
    #expect(!catalog.supportsFast("gpt-plain"), "a default tier isn't a Fast tier")
    #expect(!catalog.supportsFast("gpt-unknown"))
  }

  @Test func codexWithoutVisibilityCountsAsListed() throws {
    let catalog = try CLIModelCatalog.codex(fromCatalog: Data(FakeExecutables.codexCatalog.utf8))
    #expect(catalog.options.map(\.id) == ["", "fake-default", "fake-other"])
    #expect(catalog.supportsFast("fake-default"))
    #expect(catalog.supportsFast(""))
    #expect(!catalog.supportsFast("fake-other"))
  }

  @Test(arguments: [
    "not json",
    #"{"models":[]}"#,
    #"{"models":[{"slug":"only-hidden","visibility":"hide"}]}"#,
  ])
  func codexRejectsCatalogsWithNothingToPick(raw: String) {
    #expect(throws: CLIModelError.unreadable) {
      _ = try CLIModelCatalog.codex(fromCatalog: Data(raw.utf8))
    }
  }

  @Test func pickerKeepsASavedModelTheListDoesNotHave() throws {
    let catalog = try CLIModelCatalog.codex(fromCatalog: Data(ModelFixtures.codexCatalog.utf8))
    let listed = CLIModelCatalog.picker(catalog, selected: "gpt-astra")
    #expect(listed.saved == nil)
    #expect(listed.options == catalog.options)
    let legacy = CLIModelCatalog.picker(catalog, selected: "gpt-internal")
    #expect(legacy.saved == CLIModelOption(id: "gpt-internal", name: "gpt-internal"))
    #expect(CLIModelCatalog.picker(catalog, selected: "").saved == nil)
    // Before any list loads: the CLI default and the saved model.
    let unloaded = CLIModelCatalog.picker(nil, selected: "my-custom")
    #expect(unloaded.options == [CLIModelOption(id: "", name: "CLI default")])
    #expect(unloaded.saved?.id == "my-custom")
  }
}

/// The discovery commands, checked through fake CLIs: no user message, isolation flags,
/// sandbox, filtered environment, bounded time.
nonisolated final class CLIModelDiscoveryTests {
  let fakes: FakeExecutables

  init() throws {
    fakes = try FakeExecutables()
  }

  deinit {
    fakes.remove()
  }

  @Test func claudeAsksOnlyForInitializeUnderIsolation() async throws {
    let dir = fakes.directory.path
    try "agent rules".write(toFile: fakes.path("CLAUDE.md"), atomically: true, encoding: .utf8)
    let response = ModelFixtures.claudeInitialize(models: ModelFixtures.claudeModels)
    try response.write(toFile: fakes.path("init.jsonl"), atomically: true, encoding: .utf8)
    let claude = try fakes.script("""
      printf '%s\\0' "$@" > '\(dir)/claude-args'
      env > '\(dir)/claude-env'
      cat > '\(dir)/claude-stdin'
      cat '\(dir)/CLAUDE.md' > '\(dir)/claude-read' 2>/dev/null
      cat '\(dir)/init.jsonl'
      """, name: "claude")

    let catalog = try await CLIModelDiscovery.discover(
      engine: .claude, executable: claude, preparations: CodexPreparations(parent: fakes.directory), timeout: .seconds(10)
    )
    #expect(catalog.options.map(\.id) == ["", "opus", "fable", "sonnet", "haiku", "claude-opus-4-6"])

    let arguments = try fakes.recordedArguments("claude-args")
    #expect(arguments == CLIModelDiscovery.claudeArguments)
    #expect(arguments.value(after: "--tools") == "")
    #expect(arguments.value(after: "--setting-sources") == "")
    #expect(arguments.value(after: "--system-prompt") == "")
    #expect(arguments.value(after: "--input-format") == "stream-json")
    #expect(!arguments.contains("--model"))
    #expect(!arguments.contains("--bare"))
    let stdin = try Data(contentsOf: URL(fileURLWithPath: fakes.path("claude-stdin")))
    #expect(stdin == CLIModelCatalog.claudeInitializeRequest)
    let request = try #require(JSONSerialization.jsonObject(with: stdin) as? [String: Any])
    #expect((request["request"] as? [String: Any])?["subtype"] as? String == "initialize")
    #expect(try String(contentsOfFile: fakes.path("claude-read"), encoding: .utf8).isEmpty, "CLAUDE.md was readable")
    let env = try String(contentsOfFile: fakes.path("claude-env"), encoding: .utf8)
    #expect(env.contains("TERM=dumb"))
  }

  @Test func claudeFailureReportsTheExitWithoutAList() async throws {
    let claude = try fakes.script("cat > /dev/null; echo 'not signed in' >&2; exit 2", name: "claude")
    await #expect(throws: TranslatorError.self) {
      _ = try await CLIModelDiscovery.discover(
        engine: .claude, executable: claude, preparations: CodexPreparations(parent: self.fakes.directory), timeout: .seconds(10)
      )
    }
  }

  @Test func aCLIThatNeverAnswersIsStoppedAtTheTimeout() async throws {
    let claude = try fakes.script("echo $$ > '\(fakes.path("pid"))'; sleep 30", name: "claude")
    let started = ContinuousClock.now
    await #expect(throws: CLIModelError.timedOut) {
      _ = try await CLIModelDiscovery.discover(
        engine: .claude, executable: claude, preparations: CodexPreparations(parent: self.fakes.directory), timeout: .milliseconds(300)
      )
    }
    #expect(ContinuousClock.now - started < .seconds(4))
    #expect(await FakeExecutables.exits(try await fakes.pid(in: "pid")))
  }

  /// The refreshed catalog lists a model the bundled one lacks; after a refresh, translations
  /// use it, and the preparation a translation may still hold is left on disk.
  @Test func codexRefreshFeedsPickerAndTranslations() async throws {
    let refreshed = """
      {"models":[
        {"slug":"fake-new","display_name":"Fake New","visibility":"list","priority":1,
         "service_tiers":[{"id":"priority","name":"Fast"}],"base_instructions":"AGENT"},
        {"slug":"fake-default","visibility":"list","priority":2,"base_instructions":"AGENT"}
      ]}
      """
    try refreshed.write(toFile: fakes.path("refreshed.json"), atomically: true, encoding: .utf8)
    let dir = fakes.directory.path
    let codex = try fakes.codexScript(
      exec: "printf 'Hello' > \"$out\"",
      debug: """
        case " $* " in
          *" --bundled "*) cat '\(dir)/catalog.json' ;;
          *) cat '\(dir)/refreshed.json' ;;
        esac
        """
    )
    let parent = fakes.directory.appendingPathComponent("prepared", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let preparations = CodexPreparations(parent: parent)
    let bundled = try await preparations.prepared(executable: codex) { _ in }
    #expect(!bundled.models.contains("fake-new"))

    let catalog = try await CLIModelDiscovery.discover(
      engine: .codex, executable: codex, preparations: preparations, timeout: .seconds(10)
    )
    #expect(catalog.options.map(\.id) == ["", "fake-new", "fake-default"])
    #expect(catalog.supportsFast("fake-new"))
    let debug = try fakes.recordedArguments("debug-args")
    #expect(Array(debug.prefix(2)) == ["debug", "models"])
    #expect(!debug.contains("--bundled"))
    #expect(debug.values(of: "--disable") == CodexIsolation.disabledFeatures)

    let current = try await preparations.prepared(executable: codex) { _ in }
    #expect(current.models.contains("fake-new"))
    #expect(current.directory != bundled.directory)
    #expect(FileManager.default.fileExists(atPath: bundled.catalog.path), "an in-flight translation's catalog was removed")
    let sanitized = try String(contentsOf: current.catalog, encoding: .utf8)
    #expect(sanitized.contains("fake-new"))
    #expect(!sanitized.contains("AGENT"))
  }

  @Test func failedCodexRefreshKeepsTheCurrentPreparation() async throws {
    let codex = try fakes.codexScript(
      exec: "",
      debug: #"case " $* " in *" --bundled "*) cat '\#(fakes.path("catalog.json"))' ;; *) echo 'offline' >&2; exit 4 ;; esac"#
    )
    let parent = fakes.directory.appendingPathComponent("prepared", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let preparations = CodexPreparations(parent: parent)
    let bundled = try await preparations.prepared(executable: codex) { _ in }
    await #expect(throws: TranslatorError.self) {
      _ = try await CLIModelDiscovery.discover(
        engine: .codex, executable: codex, preparations: preparations, timeout: .seconds(10)
      )
    }
    #expect(try await preparations.prepared(executable: codex) { _ in }.directory == bundled.directory)
  }
}

/// Counts and gates discovery calls so tests decide when each answers.
actor FakeDiscovery {
  private(set) var calls: [String] = []
  private var results: [String: Result<CLIModelCatalog, Error>] = [:]
  private var delays: [String: Duration] = [:]

  func set(_ executable: String, _ result: Result<CLIModelCatalog, Error>, delay: Duration = .zero) {
    results[executable] = result
    delays[executable] = delay
  }

  func discover(_ engine: TranslationEngine, _ executable: String) async throws -> CLIModelCatalog {
    calls.append(executable)
    if let delay = delays[executable], delay > .zero {
      try await Task.sleep(for: delay)
    }
    return try (results[executable] ?? .failure(CLIModelError.unreadable)).get()
  }
}

nonisolated private func fakeCatalog(_ ids: [String], fast: Set<String> = []) -> CLIModelCatalog {
  CLIModelCatalog(
    options: [CLIModelCatalog.defaultOption(named: nil)] + ids.map { CLIModelOption(id: $0, name: $0) },
    fastModels: fast
  )
}

final class CLIModelStoreTests {
  let fakes: FakeExecutables
  let discovery = FakeDiscovery()
  let store: CLIModelStore

  init() throws {
    fakes = try FakeExecutables()
    let discovery = discovery
    store = CLIModelStore { try await discovery.discover($0, $1) }
  }

  deinit {
    fakes.remove()
  }

  @Test func loadsOncePerExecutableUntilRefreshed() async throws {
    let claude = try fakes.script("exit 0", name: "claude")
    await discovery.set(claude, .success(fakeCatalog(["opus"])))
    await store.load(.claude, override: claude)
    await store.load(.claude, override: claude)
    #expect(await discovery.calls == [claude])
    #expect(store.catalog(for: .claude, override: claude) == fakeCatalog(["opus"]))

    await discovery.set(claude, .success(fakeCatalog(["opus", "fable"])))
    await store.load(.claude, override: claude, force: true)
    #expect(await discovery.calls.count == 2)
    #expect(store.catalog(for: .claude, override: claude)?.options.map(\.id) == ["", "opus", "fable"])
  }

  @Test func failedRefreshKeepsTheLastListAndSaysSo() async throws {
    let codex = try fakes.script("exit 0", name: "codex")
    await discovery.set(codex, .success(fakeCatalog(["gpt-sol"])))
    await store.load(.codex, override: codex)
    await discovery.set(codex, .failure(TranslatorError.processFailed(status: 7, stderr: "private detail")))
    await store.load(.codex, override: codex, force: true)
    let state = store.state(for: .codex, override: codex)
    #expect(state.catalog == fakeCatalog(["gpt-sol"]))
    #expect(!state.isLoading)
    let failure = try #require(state.failure)
    #expect(failure.contains("7"))
    #expect(!failure.contains("private detail"), "stderr stays out of Settings")

    await discovery.set(codex, .success(fakeCatalog(["gpt-astra"])))
    await store.load(.codex, override: codex, force: true)
    #expect(store.state(for: .codex, override: codex).failure == nil)
  }

  @Test func aSlowAnswerForAnOldPathNeverReachesTheNewOne() async throws {
    let old = try fakes.script("exit 0", name: "claude")
    let newDirectory = fakes.directory.appendingPathComponent("new", isDirectory: true)
    try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
    let new = newDirectory.appendingPathComponent("claude").path
    try FileManager.default.copyItem(atPath: old, toPath: new)
    await discovery.set(old, .success(fakeCatalog(["old-model"])), delay: .milliseconds(300))
    await discovery.set(new, .success(fakeCatalog(["new-model"])))

    let slow = Task { await store.load(.claude, override: old) }
    try await eventually { store.state(for: .claude, override: old).isLoading }
    await store.load(.claude, override: new)
    #expect(store.catalog(for: .claude, override: new)?.options.map(\.id) == ["", "new-model"])
    await slow.value
    #expect(store.catalog(for: .claude, override: new)?.options.map(\.id) == ["", "new-model"])
    #expect(store.catalog(for: .claude, override: old)?.options.map(\.id) == ["", "old-model"])
  }

  @Test func cancelledLoadLeavesNoErrorAndCanRunAgain() async throws {
    let claude = try fakes.script("exit 0", name: "claude")
    await discovery.set(claude, .success(fakeCatalog(["opus"])), delay: .seconds(10))
    let task = Task { await store.load(.claude, override: claude) }
    try await eventually { store.state(for: .claude, override: claude).isLoading }
    task.cancel()
    await task.value
    #expect(store.state(for: .claude, override: claude) == CLIModelStore.State())
    await discovery.set(claude, .success(fakeCatalog(["opus"])))
    await store.load(.claude, override: claude)
    #expect(store.catalog(for: .claude, override: claude) != nil)
  }

  @Test func enginesWithoutACLINeverQuery() async {
    await store.load(.local, override: "")
    await store.load(.apple, override: "")
    #expect(await discovery.calls.isEmpty)
    #expect(store.state(for: .local, override: "") == CLIModelStore.State())
  }

  /// Offscreen models never launch a CLI, whatever Settings asks for.
  @Test func inertAppModelDoesNotDiscover() async throws {
    let claude = try fakes.script("exit 0", name: "claude")
    var settings = AppSettings.default
    settings.engine = .claude
    settings.claudePath = claude
    let model = AppModel(settings: settings, isLive: false, models: store)
    await model.loadModels(for: .claude, force: true)
    #expect(await discovery.calls.isEmpty)
  }

  /// Claude's Fast follows the loaded metadata for the saved model, never switching it, and
  /// a translation keeps the configuration it started with.
  @Test func claudeFastNeedsMetadataForTheSavedModel() async throws {
    let claude = try fakes.script("exit 0", name: "claude")
    var settings = AppSettings.default
    settings.engine = .claude
    settings.claudePath = claude
    settings.claudeModel = "opus"
    settings.claudeFast = true
    let model = AppModel(settings: settings, isLive: false, models: store)
    #expect(!model.engineConfiguration.fastMode, "no metadata yet")
    #expect(!model.isFastAvailable(for: .claude))

    await discovery.set(claude, .success(fakeCatalog(["opus", "haiku"], fast: ["opus"])))
    await store.load(.claude, override: claude)
    #expect(model.isFastAvailable(for: .claude))
    #expect(model.engineConfiguration == EngineConfiguration(
      engine: .claude, executableOverride: claude, model: "opus", fastMode: true
    ))

    model.settings.claudeModel = "haiku"
    #expect(!model.engineConfiguration.fastMode)
    #expect(model.settings.claudeFast, "the preference survives an unsupported model")
    #expect(model.settings.claudeModel == "haiku")

    model.settings.claudeModel = "opus"
    model.settings.claudeFast = false
    #expect(!model.engineConfiguration.fastMode)
  }
}

/// Model lists and the sanitized Codex catalog outlive the app, keyed by executable and
/// checked against it, and a bad cache never brings back coding-agent context.
final class CLIModelCacheTests {
  let fakes: FakeExecutables
  let cache: CLIModelCache

  init() throws {
    fakes = try FakeExecutables()
    cache = CLIModelCache(directory: fakes.directory.appendingPathComponent("cache", isDirectory: true))
  }

  deinit {
    fakes.remove()
  }

  @Test func catalogRoundTripsPrivatelyPerEngineAndExecutable() throws {
    let claude = try fakes.script("exit 0", name: "claude")
    let saved = fakeCatalog(["opus"], fast: ["", "opus"])
    cache.save(saved, engine: .claude, executable: claude)
    #expect(cache.catalog(engine: .claude, executable: claude) == saved)
    #expect(cache.catalog(engine: .codex, executable: claude) == nil)
    #expect(cache.catalog(engine: .claude, executable: fakes.path("other")) == nil)
    let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
    #expect(files.count == 1)
    for file in files {
      let attributes = try FileManager.default.attributesOfItem(atPath: cache.directory.appendingPathComponent(file).path)
      #expect(attributes[.posixPermissions] as? Int == 0o600)
    }
  }

  @Test func changedExecutableOrCorruptFileIsIgnored() throws {
    let claude = try fakes.script("exit 0", name: "claude")
    cache.save(fakeCatalog(["opus"]), engine: .claude, executable: claude)
    _ = try fakes.script("exit 0 # updated", name: "claude")
    #expect(cache.catalog(engine: .claude, executable: claude) == nil, "an updated CLI must list again")

    cache.save(fakeCatalog(["opus"]), engine: .claude, executable: claude)
    for file in try FileManager.default.contentsOfDirectory(atPath: cache.directory.path) {
      try Data("{not json".utf8).write(to: cache.directory.appendingPathComponent(file))
    }
    #expect(cache.catalog(engine: .claude, executable: claude) == nil)
  }

  @Test func storeShowsTheSavedListAtOnceAndStillRefreshesOncePerSession() async throws {
    let claude = try fakes.script("exit 0", name: "claude")
    cache.save(fakeCatalog(["opus"], fast: ["opus"]), engine: .claude, executable: claude)
    let discovery = FakeDiscovery()
    await discovery.set(claude, .success(fakeCatalog(["opus", "fable"], fast: ["opus", "fable"])))
    let store = CLIModelStore(cache: cache) { try await discovery.discover($0, $1) }
    #expect(store.catalog(for: .claude, override: claude) == fakeCatalog(["opus"], fast: ["opus"]))

    await store.load(.claude, override: claude)
    await store.load(.claude, override: claude)
    #expect(await discovery.calls == [claude])
    #expect(store.catalog(for: .claude, override: claude)?.options.map(\.id) == ["", "opus", "fable"])

    // The next launch starts from the refreshed list.
    let relaunched = CLIModelStore(cache: cache) { try await discovery.discover($0, $1) }
    #expect(relaunched.catalog(for: .claude, override: claude)?.options.map(\.id) == ["", "opus", "fable"])
  }

  @Test func failedRefreshKeepsTheSavedList() async throws {
    let codex = try fakes.script("exit 0", name: "codex")
    cache.save(fakeCatalog(["gpt-sol"]), engine: .codex, executable: codex)
    let store = CLIModelStore(cache: cache) { _, _ in throw CLIModelError.timedOut }
    await store.load(.codex, override: codex)
    let state = store.state(for: .codex, override: codex)
    #expect(state.catalog == fakeCatalog(["gpt-sol"]))
    #expect(state.failure != nil)
    #expect(cache.catalog(engine: .codex, executable: codex) == fakeCatalog(["gpt-sol"]))
  }

  /// After a relaunch, Claude's Fast follows the saved list without opening Settings.
  @Test func claudeFastWorksAfterRelaunchWithoutSettings() throws {
    let claude = try fakes.script("exit 0", name: "claude")
    cache.save(fakeCatalog(["opus", "haiku"], fast: ["opus"]), engine: .claude, executable: claude)
    var settings = AppSettings.default
    settings.engine = .claude
    settings.claudePath = claude
    settings.claudeModel = "opus"
    settings.claudeFast = true
    let model = AppModel(settings: settings, isLive: false, models: CLIModelStore(cache: cache) { _, _ in
      throw CLIModelError.unreadable
    })
    #expect(model.engineConfiguration.fastMode)
    model.settings.claudeModel = "haiku"
    #expect(!model.engineConfiguration.fastMode)
  }

  // MARK: Codex catalog

  private func codexWithRefreshedCatalog() throws -> String {
    let refreshed = """
      {"models":[
        {"slug":"fake-new","display_name":"Fake New","visibility":"list","priority":1,
         "service_tiers":[{"id":"priority","name":"Fast"}],"tool_mode":"code_mode_only",
         "base_instructions":"AGENT"}
      ]}
      """
    try refreshed.write(toFile: fakes.path("refreshed.json"), atomically: true, encoding: .utf8)
    let dir = fakes.directory.path
    return try fakes.codexScript(
      exec: "printf 'Hello' > \"$out\"",
      debug: """
        case " $* " in
          *" --bundled "*) cat '\(dir)/catalog.json' ;;
          *) cat '\(dir)/refreshed.json' ;;
        esac
        """
    )
  }

  private func preparations() throws -> CodexPreparations {
    let parent = fakes.directory.appendingPathComponent("prepared-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return CodexPreparations(parent: parent, cache: cache)
  }

  @Test func refreshedCodexCatalogIsUsedAfterRelaunchWithoutListingAgain() async throws {
    let codex = try codexWithRefreshedCatalog()
    _ = try await preparations().refresh(executable: codex) { _ in }
    #expect(try String(contentsOfFile: fakes.path("debug-count"), encoding: .utf8) == "run\n")

    let relaunched = try await preparations().prepared(executable: codex) { _ in }
    #expect(relaunched.models == ["fake-new"])
    #expect(relaunched.metadata.supportsFast("fake-new"))
    #expect(try String(contentsOfFile: fakes.path("debug-count"), encoding: .utf8) == "run\n", "listed again")
    let restored = try String(contentsOf: relaunched.catalog, encoding: .utf8)
    #expect(!restored.contains("AGENT"))
    #expect(!restored.contains("code_mode_only"))
    #expect(!FileManager.default.fileExists(atPath: relaunched.directory.appendingPathComponent("instructions.md").path))
  }

  /// A cached catalog someone edited back into an agent setup is sanitized again on load.
  @Test func tamperedCodexCatalogIsSanitizedAgain() async throws {
    let codex = try codexWithRefreshedCatalog()
    _ = try await preparations().refresh(executable: codex) { _ in }
    for file in try FileManager.default.contentsOfDirectory(atPath: cache.directory.path) {
      let url = cache.directory.appendingPathComponent(file)
      let text = try String(contentsOf: url, encoding: .utf8)
      try text.replacingOccurrences(of: "direct", with: "code_mode_only").write(to: url, atomically: true, encoding: .utf8)
    }
    let relaunched = try await preparations().prepared(executable: codex) { _ in }
    let restored = try String(contentsOf: relaunched.catalog, encoding: .utf8)
    #expect(!restored.contains("code_mode_only"))
  }

  @Test func unusableCodexCacheFallsBackToTheBundledCatalog() async throws {
    let codex = try codexWithRefreshedCatalog()
    _ = try await preparations().refresh(executable: codex) { _ in }
    for file in try FileManager.default.contentsOfDirectory(atPath: cache.directory.path) {
      try Data("{not json".utf8).write(to: cache.directory.appendingPathComponent(file))
    }
    let relaunched = try await preparations().prepared(executable: codex) { _ in }
    #expect(relaunched.models == ["fake-default", "fake-other"])
    #expect(try fakes.recordedArguments("debug-args").contains("--bundled"))
    #expect(!(try String(contentsOf: relaunched.catalog, encoding: .utf8)).contains("AGENT"))
  }
}
