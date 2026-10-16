import Darwin
import Foundation

/// Runs a translation CLI under one extra read restriction: it can't open agent
/// instruction or skill files anywhere on disk, whatever its own settings load. Everything
/// else, including the CLI's sign-in, works as usual. There is no unrestricted fallback.
nonisolated enum CLISandbox {
  static let launcher = "/usr/bin/sandbox-exec"
  static let profile = ##"(version 1)(allow default)(deny file-read-data (regex #"/(AGENTS([.]override)?[.]md|SKILL[.]md|CLAUDE[.]md)$"))"##

  static func command(
    executable: String,
    arguments: [String],
    currentDirectory: String,
    stdoutIsTerminal: Bool = false,
    environment: [String: String] = ShellEnvironment.processEnvironment(),
    launcher: String = CLISandbox.launcher
  ) throws -> CLICommand {
    guard FileManager.default.isExecutableFile(atPath: launcher) else {
      throw TranslatorError.isolationFailed("Couldn't find macOS sandbox-exec, so the CLI can't run isolated.")
    }
    return CLICommand(
      executable: launcher,
      arguments: ["-p", profile, executable] + arguments,
      environment: environment,
      currentDirectory: currentDirectory,
      stdoutIsTerminal: stdoutIsTerminal
    )
  }
}

/// Codex arrives as a coding agent: tools, skills, plugins, sub-agents and long default
/// instructions, some set by the CLI's model catalog rather than its config. A translation
/// turns all of that off and sends only the system prompt and the text.
nonisolated enum CodexIsolation {
  static let disabledFeatures = [
    "shell_tool", "unified_exec", "view_image", "image_generation", "browser_use",
    "browser_use_external", "apps", "plugins", "remote_plugin", "hooks", "multi_agent",
    "multi_agent_v2", "sleep_tool", "tool_suggest", "skill_search", "skill_mcp_dependency_install",
    "shell_snapshot", "memories", "workspace_dependencies", "code_mode_host", "code_mode", "goals",
  ]

  static let featureArguments = disabledFeatures.flatMap { ["--disable", $0] }
    + ["--enable", "skip_host_skill_discovery"]

  /// The catalog Codex prints can be large; anything past this isn't a catalog.
  static let catalogLimit = 32 * 1024 * 1024

  static func execArguments(
    _ prepared: PreparedCodex,
    model: String,
    messageFile: String,
    prompt: String
  ) -> [String] {
    var arguments = [
      "exec",
      "--ignore-user-config",
      "--ignore-rules",
      "--skip-git-repo-check",
      "--ephemeral",
      "--sandbox", "read-only",
      "--color", "never",
      "--output-last-message", messageFile,
    ] + featureArguments
    let overrides = [
      ("model_catalog_json", toml(prepared.catalog.path)),
      ("model_instructions_file", toml(prepared.instructions.path)),
      ("developer_instructions", toml("")),
      ("project_doc_max_bytes", "0"),
      ("skills.bundled.enabled", "false"),
      ("skills.include_instructions", "false"),
      ("tools.update_plan.enabled", "false"),
      ("tools.experimental_request_user_input.enabled", "false"),
      ("web_search", toml("disabled")),
      ("mcp_servers", "{}"),
      ("plugins", "{}"),
      ("include_apps_instructions", "false"),
      ("include_collaboration_mode_instructions", "false"),
      ("include_permissions_instructions", "false"),
      ("include_environment_context", "false"),
      ("model_reasoning_effort", toml("low")),
      ("model_reasoning_summary", toml("none")),
      ("model_verbosity", toml("low")),
    ]
    for (key, value) in overrides {
      arguments += ["-c", "\(key)=\(value)"]
    }
    if !model.isEmpty {
      arguments += ["--model", model]
    }
    arguments.append(prompt)
    return arguments
  }

  /// The CLI's catalog with every model kept, but each one set to plain direct responses:
  /// no code mode, sub-agents, patch or experimental tools, usage instructions, or default
  /// agent instructions. Returns the JSON to write and the model IDs it lists.
  static func sanitizedCatalog(_ raw: Data, instructions: String) throws -> (data: Data, models: Set<String>) {
    let invalid = TranslatorError.isolationFailed("Codex returned a model list this app can't read.")
    guard var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          let models = root["models"] as? [[String: Any]], !models.isEmpty else {
      throw invalid
    }
    var slugs = Set<String>()
    root["models"] = try models.map { model in
      guard let slug = model["slug"] as? String, !slug.isEmpty else { throw invalid }
      slugs.insert(slug)
      var model = model
      model["tool_mode"] = "direct"
      model["model_messages"] = NSNull()
      model["apply_patch_tool_type"] = NSNull()
      model["experimental_supported_tools"] = [String]()
      model["multi_agent_version"] = NSNull()
      model["include_skills_usage_instructions"] = false
      model["include_plugin_usage_instructions"] = false
      model["include_apps_usage_instructions"] = false
      model["base_instructions"] = instructions
      return model
    }
    return (try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), slugs)
  }

  /// Reads the installed CLI's catalog and writes the sanitized copy and the instructions
  /// into a new directory under `parent`. Lists models only; no model is called. Nothing is
  /// left behind when it fails or is cancelled.
  static func prepare(
    executable: String,
    in parent: URL,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> PreparedCodex {
    let directory = parent.appendingPathComponent("\(directoryPrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      let command = try CLISandbox.command(
        executable: executable,
        arguments: ["debug", "models", "--bundled"] + featureArguments,
        currentDirectory: directory.path
      )
      let output = CatalogOutput()
      let exit = try await CLIProcess.run(command) { await output.append($0) }
      await trace("codex catalog exit \(exit.status), \(exit.stdoutBytes) bytes")
      guard exit.status == 0 else {
        throw TranslatorError.processFailed(status: exit.status, stderr: exit.stderr)
      }
      guard let raw = await output.data else {
        throw TranslatorError.isolationFailed("Codex returned a model list this app can't read.")
      }
      let catalog = try sanitizedCatalog(raw, instructions: PromptBuilder.systemPrompt)
      let prepared = PreparedCodex(directory: directory, models: catalog.models)
      try catalog.data.write(to: prepared.catalog)
      try PromptBuilder.systemPrompt.write(to: prepared.instructions, atomically: true, encoding: .utf8)
      await trace("codex catalog \(catalog.models.count) models prepared")
      return prepared
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  static let directoryPrefix = "translate-codex-"

  /// Removes directories that earlier runs of the app left in `parent`. Only directories
  /// whose owning process is gone are touched.
  static func removeStaleDirectories(in parent: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names where name.hasPrefix(directoryPrefix) {
      let owner = name.dropFirst(directoryPrefix.count).prefix { $0 != "-" }
      guard let pid = pid_t(owner), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
      try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
    }
  }

  private static func toml(_ string: String) -> String {
    "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}

/// The sanitized catalog and the instructions file for one Codex executable.
nonisolated struct PreparedCodex: Sendable {
  var directory: URL
  var models: Set<String>
  var catalog: URL { directory.appendingPathComponent("models.json") }
  var instructions: URL { directory.appendingPathComponent("instructions.md") }
}

/// Prepares each Codex executable once per app process. A CLI updated while the app runs is
/// picked up on the next launch. Failures aren't kept, so the next translation tries again.
actor CodexPreparations {
  static let shared = CodexPreparations()

  private let parent: URL
  private var ready: [String: PreparedCodex] = [:]
  private var swept = false

  init(parent: URL = FileManager.default.temporaryDirectory) {
    self.parent = parent
  }

  func prepared(
    executable: String,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> PreparedCodex {
    if let existing = ready[executable] {
      await trace("codex catalog reused")
      return existing
    }
    if !swept {
      swept = true
      CodexIsolation.removeStaleDirectories(in: parent)
    }
    let fresh = try await CodexIsolation.prepare(executable: executable, in: parent, trace: trace)
    // Another translation may have finished preparing while this one waited.
    if let existing = ready[executable] {
      try? FileManager.default.removeItem(at: fresh.directory)
      return existing
    }
    ready[executable] = fresh
    return fresh
  }
}

/// Collects the catalog from stdout, giving up past `CodexIsolation.catalogLimit`.
private actor CatalogOutput {
  private var buffer = Data()
  private var overflowed = false

  func append(_ chunk: String) {
    guard !overflowed else { return }
    buffer.append(contentsOf: chunk.utf8)
    if buffer.count > CodexIsolation.catalogLimit {
      overflowed = true
      buffer = Data()
    }
  }

  var data: Data? { overflowed ? nil : buffer }
}
