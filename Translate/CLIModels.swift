import CryptoKit
import Foundation
import os

nonisolated private let log = Logger(subsystem: "com.frank.translate", category: "models")

/// One entry in a CLI's model picker. The empty ID is the CLI's own default: no `--model`.
nonisolated struct CLIModelOption: Codable, Sendable, Hashable, Identifiable {
  var id: String
  var name: String
}

/// What a CLI says it can run: picker entries and which models take Fast. Only IDs, names
/// and that one capability are kept from the CLI's metadata.
nonisolated struct CLIModelCatalog: Codable, Sendable, Equatable {
  /// The CLI default first, then the models the CLI lists, in its order.
  var options: [CLIModelOption]
  /// Every ID the CLI runs with Fast, including aliases' resolved IDs and hidden models.
  /// Contains "" when the CLI default does.
  var fastModels: Set<String>

  func supportsFast(_ model: String) -> Bool {
    fastModels.contains(model.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func defaultOption(named name: String?) -> CLIModelOption {
    CLIModelOption(id: "", name: name.map { "CLI default (\($0))" } ?? "CLI default")
  }

  /// The picker's entries, plus the saved model as its own entry when the catalog doesn't
  /// list it, so a legacy or custom choice stays selected exactly as written.
  static func picker(_ catalog: CLIModelCatalog?, selected: String) -> (options: [CLIModelOption], saved: CLIModelOption?) {
    let options = catalog?.options ?? [defaultOption(named: nil)]
    guard !selected.isEmpty, !options.contains(where: { $0.id == selected }) else { return (options, nil) }
    return (options, CLIModelOption(id: selected, name: selected))
  }

  // MARK: Claude

  static let claudeInitializeRequestID = "models-only"

  /// Claude's SDK initialize request: one line, then EOF. It asks for session metadata only;
  /// no user message is sent, so no model runs.
  static let claudeInitializeRequest = Data(
    (#"{"type":"control_request","request_id":"\#(claudeInitializeRequestID)","request":{"subtype":"initialize"}}"# + "\n").utf8
  )

  /// Reads the models from Claude's initialize response and drops everything else in it,
  /// account and commands included, without logging it.
  static func claude(fromInitializeOutput output: Data) throws -> CLIModelCatalog {
    for line in output.split(separator: UInt8(ascii: "\n")) {
      guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
            message["type"] as? String == "control_response",
            let response = message["response"] as? [String: Any],
            response["request_id"] as? String == claudeInitializeRequestID else { continue }
      guard response["subtype"] as? String == "success",
            let session = response["response"] as? [String: Any],
            let models = session["models"] as? [[String: Any]] else { break }
      return try claude(models: models)
    }
    throw CLIModelError.unreadable
  }

  private static func claude(models: [[String: Any]]) throws -> CLIModelCatalog {
    var listed: [CLIModelOption] = []
    var seen: Set<String> = [""]
    var fast: Set<String> = []
    var defaultName: String?
    var defaultResolved: String?
    var defaultFast = false
    var names: [String: String] = [:]
    for model in models {
      guard let value = model["value"] as? String, !value.isEmpty else { continue }
      let supportsFast = model["supportsFastMode"] as? Bool ?? false
      let resolved = model["resolvedModel"] as? String
      let name = (model["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
      if value == "default" {
        defaultResolved = resolved
        defaultFast = supportsFast
        continue
      }
      if let resolved, names[resolved] == nil { names[resolved] = name }
      if supportsFast {
        fast.insert(value)
        if let resolved { fast.insert(resolved) }
      }
      guard seen.insert(value).inserted else { continue }
      listed.append(CLIModelOption(id: value, name: name))
    }
    guard !listed.isEmpty || defaultResolved != nil else { throw CLIModelError.unreadable }
    if let defaultResolved {
      defaultName = names[defaultResolved] ?? defaultResolved
    }
    if defaultFast { fast.insert("") }
    return CLIModelCatalog(options: [defaultOption(named: defaultName)] + listed, fastModels: fast)
  }

  // MARK: Codex

  /// Models the CLI shows (`visibility: list`, or no visibility at all) by its priority; the
  /// first is what it runs without `--model`. Fast is a `priority` service tier, which is
  /// what `service_tier` sends; hidden models keep their capability for saved selections.
  static func codex(fromCatalog raw: Data) throws -> CLIModelCatalog {
    guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          let models = root["models"] as? [[String: Any]] else { throw CLIModelError.unreadable }
    var listed: [(priority: Int, option: CLIModelOption)] = []
    var seen: Set<String> = [""]
    var fast: Set<String> = []
    for model in models {
      guard let slug = model["slug"] as? String, !slug.isEmpty else { continue }
      let tiers = model["service_tiers"] as? [[String: Any]] ?? []
      if tiers.contains(where: { $0["id"] as? String == "priority" }) {
        fast.insert(slug)
      }
      let visibility = model["visibility"] as? String ?? "list"
      guard visibility == "list", seen.insert(slug).inserted else { continue }
      let name = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
      listed.append((model["priority"] as? Int ?? .max, CLIModelOption(id: slug, name: name)))
    }
    let ordered = listed.enumerated()
      .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
      .map(\.element.option)
    guard let first = ordered.first else { throw CLIModelError.unreadable }
    if fast.contains(first.id) { fast.insert("") }
    return CLIModelCatalog(options: [defaultOption(named: first.name)] + ordered, fastModels: fast)
  }
}

nonisolated enum CLIModelError: LocalizedError, Sendable, Equatable {
  case notFound(String)
  case unreadable
  case timedOut

  var errorDescription: String? {
    switch self {
    case .notFound(let name): "Couldn’t find \(name)."
    case .unreadable: "The CLI returned a model list this app can’t read."
    case .timedOut: "The CLI didn’t list its models in time."
    }
  }
}

/// Asks an installed CLI which models it offers, through the same sandbox and filtered
/// environment as a translation. Neither query sends a message to a model.
nonisolated enum CLIModelDiscovery {
  static let timeout: Duration = .seconds(30)
  static let claudeOutputLimit = 4 * 1024 * 1024

  /// The isolation flags a translation uses, with an empty system prompt and stream-json
  /// input so the initialize request is the only thing sent.
  static let claudeArguments = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--verbose",
    "--tools", "",
    "--strict-mcp-config",
    "--mcp-config", #"{"mcpServers":{}}"#,
    "--setting-sources", "",
    "--no-session-persistence",
    "--disable-slash-commands",
    "--safe-mode",
    "--system-prompt", "",
  ]

  @concurrent
  static func discover(engine: TranslationEngine, executable: String) async throws -> CLIModelCatalog {
    try await discover(engine: engine, executable: executable, preparations: .shared, timeout: timeout)
  }

  /// Codex's refreshed catalog also becomes the sanitized catalog its translations use.
  @concurrent
  static func discover(
    engine: TranslationEngine,
    executable: String,
    preparations: CodexPreparations,
    timeout: Duration
  ) async throws -> CLIModelCatalog {
    try await withTimeout(timeout) {
      switch engine {
      case .claude:
        return try await claude(executable: executable)
      case .codex:
        return try await preparations.refresh(executable: executable) { line in
          log.info("\(line, privacy: .public)")
        }.metadata
      case .local, .apple:
        throw CLIModelError.unreadable
      }
    }
  }

  private static func claude(executable: String) async throws -> CLIModelCatalog {
    var command = try CLISandbox.command(
      executable: executable,
      arguments: claudeArguments,
      currentDirectory: NSTemporaryDirectory()
    )
    command.stdin = CLIModelCatalog.claudeInitializeRequest
    let output = BoundedOutput(limit: claudeOutputLimit)
    let exit = try await CLIProcess.run(command) { await output.append($0) }
    log.info("claude models exit \(exit.status, privacy: .public), \(exit.stdoutBytes, privacy: .public) bytes")
    guard let data = await output.data else { throw CLIModelError.unreadable }
    // The response is read even after a nonzero exit: it was complete before the CLI quit.
    do {
      return try CLIModelCatalog.claude(fromInitializeOutput: data)
    } catch {
      guard exit.status == 0 else { throw TranslatorError.processFailed(status: exit.status, stderr: exit.stderr) }
      throw error
    }
  }

  /// Runs `operation`, cancelling it (and so stopping its CLI) once `limit` passes.
  static func withTimeout<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: limit)
        return nil
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() ?? nil else { throw CLIModelError.timedOut }
      return value
    }
  }
}

/// Model lists per resolved executable, fetched only while Settings is open and kept in
/// `cache` for later launches. The saved list shows at once and is refreshed once per
/// session. A failed or cancelled refresh keeps what was loaded before, and a result only
/// ever lands on the executable it was read from, so editing the path can't mix lists.
@Observable
final class CLIModelStore {
  struct State: Equatable {
    var catalog: CLIModelCatalog?
    var isLoading = false
    var failure: String?
  }

  typealias Discover = @Sendable (TranslationEngine, String) async throws -> CLIModelCatalog

  /// This session's answers, by engine and executable.
  private(set) var states: [String: State] = [:]
  @ObservationIgnored private let discover: Discover
  @ObservationIgnored private let cache: CLIModelCache?
  /// What `cache` held for each key when first asked, read from disk once per session.
  @ObservationIgnored private var saved: [String: CLIModelCatalog?] = [:]

  init(
    cache: CLIModelCache? = nil,
    discover: @escaping Discover = { try await CLIModelDiscovery.discover(engine: $0, executable: $1) }
  ) {
    self.cache = cache
    self.discover = discover
  }

  static func executable(for engine: TranslationEngine, override: String) -> String? {
    ShellEnvironment.resolveExecutable(named: engine.executableName, override: override)
  }

  private static func key(_ engine: TranslationEngine, _ executable: String) -> String {
    "\(engine.rawValue):\(executable)"
  }

  func state(for engine: TranslationEngine, override: String) -> State {
    guard engine == .claude || engine == .codex else { return State() }
    guard let executable = Self.executable(for: engine, override: override) else {
      return State(failure: CLIModelError.notFound(engine.executableName).errorDescription)
    }
    let key = Self.key(engine, executable)
    var state = states[key] ?? State()
    if state.catalog == nil {
      state.catalog = savedCatalog(key: key, engine: engine, executable: executable)
    }
    return state
  }

  private func savedCatalog(key: String, engine: TranslationEngine, executable: String) -> CLIModelCatalog? {
    if let known = saved[key] { return known }
    let catalog = cache?.catalog(engine: engine, executable: executable)
    saved[key] = catalog
    return catalog
  }

  func catalog(for engine: TranslationEngine, override: String) -> CLIModelCatalog? {
    state(for: engine, override: override).catalog
  }

  /// Asks once per executable and session unless `force`. Returns when the CLI has
  /// answered, failed or been cancelled.
  func load(_ engine: TranslationEngine, override: String, force: Bool = false) async {
    guard engine == .claude || engine == .codex,
          let executable = Self.executable(for: engine, override: override) else { return }
    let key = Self.key(engine, executable)
    var state = states[key] ?? State()
    guard !state.isLoading, force || state.catalog == nil else { return }
    state.isLoading = true
    states[key] = state
    let discover = discover
    let result: Result<CLIModelCatalog, Error>
    do {
      result = .success(try await discover(engine, executable))
    } catch {
      result = .failure(error)
    }
    state = states[key] ?? State()
    state.isLoading = false
    switch result {
    case .success(let catalog):
      state.catalog = catalog
      state.failure = nil
      saved[key] = catalog
      cache?.save(catalog, engine: engine, executable: executable)
    case .failure(TranslatorError.processFailed(let status, _)):
      log.error("model list failed: exit \(status, privacy: .public)")
      state.failure = "The CLI couldn’t list its models (exit \(status))."
    case .failure(let error as TranslatorError):
      log.error("model list failed: \(error.logSummary, privacy: .public)")
      state.failure = error.errorDescription
    case .failure(is CancellationError):
      break
    case .failure(let error):
      log.error("model list failed")
      state.failure = error.localizedDescription
    }
    states[key] = state
  }
}

/// Model lists and the sanitized Codex catalog on disk, one owner-only file each per engine
/// and executable. An entry only counts for the same executable file, unchanged since it was
/// saved; anything else, or anything unreadable, is as good as missing.
nonisolated struct CLIModelCache: Sendable {
  let directory: URL

  /// Nil while the app hosts tests, so they never read or write the user's cache.
  static let live: CLIModelCache? = {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
          let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    return CLIModelCache(directory: caches.appendingPathComponent("com.frank.translate/Models", isDirectory: true))
  }()

  private static let version = 1

  private struct Entry: Codable {
    var version: Int
    var executable: String
    var fingerprint: String
    var catalog: CLIModelCatalog
  }

  func catalog(engine: TranslationEngine, executable: String) -> CLIModelCatalog? {
    guard let data = try? Data(contentsOf: url(engine, executable, "models")),
          let entry = try? JSONDecoder().decode(Entry.self, from: data),
          entry.version == Self.version, entry.executable == executable,
          entry.fingerprint == Self.fingerprint(executable) else { return nil }
    return entry.catalog
  }

  func save(_ catalog: CLIModelCatalog, engine: TranslationEngine, executable: String) {
    guard let fingerprint = Self.fingerprint(executable),
          let data = try? JSONEncoder().encode(Entry(
            version: Self.version, executable: executable, fingerprint: fingerprint, catalog: catalog
          )) else { return }
    write(data, to: url(engine, executable, "models"))
  }

  /// The sanitized catalog as saved. Callers sanitize it again before using it.
  func codexCatalog(executable: String) -> Data? {
    guard let data = try? Data(contentsOf: url(.codex, executable, "catalog")),
          let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          entry["version"] as? Int == Self.version, entry["executable"] as? String == executable,
          let fingerprint = entry["fingerprint"] as? String, fingerprint == Self.fingerprint(executable),
          let catalog = entry["catalog"] as? [String: Any] else { return nil }
    return try? JSONSerialization.data(withJSONObject: catalog)
  }

  func saveCodexCatalog(_ sanitized: Data, executable: String) {
    guard let fingerprint = Self.fingerprint(executable),
          let catalog = try? JSONSerialization.jsonObject(with: sanitized),
          let data = try? JSONSerialization.data(withJSONObject: [
            "version": Self.version, "executable": executable, "fingerprint": fingerprint, "catalog": catalog,
          ] as [String: Any]) else { return }
    write(data, to: url(.codex, executable, "catalog"))
  }

  private func url(_ engine: TranslationEngine, _ executable: String, _ kind: String) -> URL {
    let digest = SHA256.hash(data: Data("\(engine.rawValue)\0\(executable)".utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(name).\(kind).json")
  }

  private func write(_ data: Data, to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
      )
      let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
      guard FileManager.default.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]
      ) else { return }
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      log.error("model cache write failed")
    }
  }

  /// The executable's real file, size and modification time: an update invalidates entries.
  static func fingerprint(_ executable: String) -> String? {
    let real = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: real),
          let size = attributes[.size] as? NSNumber,
          let modified = attributes[.modificationDate] as? Date else { return nil }
    return "\(real)|\(size)|\(modified.timeIntervalSince1970)"
  }
}

/// Collects stdout up to `limit` bytes; past that the output is discarded as not metadata.
actor BoundedOutput {
  private let limit: Int
  private var buffer = Data()
  private var overflowed = false

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: String) {
    guard !overflowed else { return }
    buffer.append(contentsOf: chunk.utf8)
    if buffer.count > limit {
      overflowed = true
      buffer = Data()
    }
  }

  var data: Data? { overflowed ? nil : buffer }
}
