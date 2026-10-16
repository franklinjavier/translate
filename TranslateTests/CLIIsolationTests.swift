import Darwin
import Foundation
import Testing
@testable import Translate

nonisolated extension FakeExecutables {
  /// Two models still set up as coding agents, the way Codex's own catalog arrives.
  static let codexCatalog = """
    {"models":[
      {"slug":"fake-default","priority":1,"context_window":1000,"tool_mode":"code_mode_only",
       "model_messages":{"instructions_template":"AGENT"},"apply_patch_tool_type":"freeform",
       "experimental_supported_tools":["clock"],"multi_agent_version":"v2",
       "include_skills_usage_instructions":true,"include_plugin_usage_instructions":true,
       "include_apps_usage_instructions":true,"base_instructions":"AGENT INSTRUCTIONS",
       "supported_reasoning_levels":[{"effort":"low"}]},
      {"slug":"fake-other","priority":2,"tool_mode":"code_mode_only","multi_agent_version":"v2",
       "base_instructions":"AGENT INSTRUCTIONS"}
    ]}
    """

  /// A fake `codex`. `debug models` counts itself, records its arguments and prints
  /// `catalog` unless `debug` replaces that. `exec` records its arguments and environment,
  /// tries to read an AGENTS.md and an ordinary file beside it, then runs `exec` with `$out`
  /// set to the final message file.
  func codexScript(exec: String, debug: String? = nil, catalog: String = codexCatalog) throws -> String {
    let dir = directory.path
    try catalog.write(toFile: path("catalog.json"), atomically: true, encoding: .utf8)
    try "agent rules".write(toFile: path("AGENTS.md"), atomically: true, encoding: .utf8)
    try "ordinary".write(toFile: path("notes.txt"), atomically: true, encoding: .utf8)
    return try script("""
      if [ "$1" = debug ]; then
        echo run >> '\(dir)/debug-count'
        printf '%s\\0' "$@" > '\(dir)/debug-args'
        \(debug ?? "cat '\(dir)/catalog.json'")
        exit 0
      fi
      printf '%s\\0' "$@" > '\(dir)/exec-args'
      env > '\(dir)/exec-env'
      cat '\(dir)/AGENTS.md' > '\(dir)/exec-agents' 2>/dev/null
      cat '\(dir)/notes.txt' > '\(dir)/exec-notes' 2>/dev/null
      out=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "--output-last-message" ]; then out="$2"; shift; fi
        shift
      done
      \(exec)
      """, name: "codex")
  }

  /// Arguments a fake recorded with `printf '%s\0'`, empty ones included.
  func recordedArguments(_ file: String) throws -> [String] {
    let text = try String(contentsOfFile: path(file), encoding: .utf8)
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  func exists(_ file: String) -> Bool {
    FileManager.default.fileExists(atPath: path(file))
  }
}

nonisolated extension [String] {
  func value(after flag: String) -> String? {
    guard let index = firstIndex(of: flag), index + 1 < count else { return nil }
    return self[index + 1]
  }

  /// Every value given to a repeatable option, e.g. all `--disable` features.
  func values(of flag: String) -> [String] {
    indices.filter { self[$0] == flag && $0 + 1 < count }.map { self[$0 + 1] }
  }
}

/// What the translation CLIs actually receive, checked through fakes the real `Translator`
/// launches: no tools, MCP, skills, plugins, hooks or instruction files, and a child
/// environment carrying only runtime basics and sign-in.
nonisolated final class CLIIsolationTests {
  static let text = "segredo"
  let fakes: FakeExecutables

  init() throws {
    fakes = try FakeExecutables()
  }

  deinit {
    fakes.remove()
  }

  func translate(_ engine: TranslationEngine, executable: String, model: String = "") async -> (Result<String, Error>, [String]) {
    let translator = Translator(configuration: EngineConfiguration(engine: engine, executableOverride: executable, model: model))
    let traces = OutputLog()
    do {
      let text = try await translator.translate(
        text: Self.text,
        targetLanguage: "english",
        onOutput: { await traces.append($0) },
        onPartial: { _ in }
      )
      return (.success(text), await traces.chunks)
    } catch {
      return (.failure(error), await traces.chunks)
    }
  }

  func expectChildEnvironmentIsFiltered(_ file: String) throws {
    let lines = try String(contentsOfFile: fakes.path(file), encoding: .utf8).split(separator: "\n")
    let names = Set(lines.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
    let shell: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "NO_COLOR"]
    let unexpected = names.filter { !ShellEnvironment.inheritedNames.contains($0) && !$0.hasPrefix("LC_") && !shell.contains($0) }
    #expect(unexpected.isEmpty, "child inherited \(unexpected.sorted())")
    #expect(lines.contains("TERM=dumb"))
    #expect(lines.contains("NO_COLOR=1"))
  }

  // MARK: Claude

  @Test func claudeRunsWithoutToolsMCPSettingsOrSkills() async throws {
    try "agent rules".write(toFile: fakes.path("CLAUDE.md"), atomically: true, encoding: .utf8)
    let dir = fakes.directory.path
    let claude = try fakes.script("""
      printf '%s\\0' "$@" > '\(dir)/claude-args'
      env > '\(dir)/claude-env'
      cat '\(dir)/CLAUDE.md' > '\(dir)/claude-read' 2>/dev/null
      printf '%s\\n' '{"type":"result","subtype":"success","result":"secret"}'
      """, name: "claude")

    let (result, _) = await translate(.claude, executable: claude)
    #expect(try result.get() == "secret")

    let arguments = try fakes.recordedArguments("claude-args")
    #expect(arguments.value(after: "--tools") == "")
    #expect(arguments.contains("--strict-mcp-config"))
    #expect(arguments.value(after: "--mcp-config") == #"{"mcpServers":{}}"#)
    #expect(arguments.value(after: "--setting-sources") == "")
    #expect(arguments.contains("--safe-mode"))
    #expect(arguments.contains("--disable-slash-commands"))
    #expect(arguments.contains("--no-session-persistence"))
    #expect(arguments.value(after: "--effort") == "low")
    #expect(arguments.value(after: "--system-prompt") == PromptBuilder.systemPrompt)
    // --bare can't sign in with a subscription.
    #expect(!arguments.contains("--bare"))
    #expect(!arguments.contains("--model"))
    #expect(arguments.last == PromptBuilder.userPrompt(text: Self.text, targetLanguage: "english"))

    try expectChildEnvironmentIsFiltered("claude-env")
    let read = try String(contentsOfFile: fakes.path("claude-read"), encoding: .utf8)
    #expect(read.isEmpty, "CLAUDE.md was readable")
  }

  // MARK: Codex

  @Test func codexRunsIsolatedAndPreparesTheCatalogOnce() async throws {
    let codex = try fakes.codexScript(exec: "printf 'Hello' > \"$out\"")

    let (first, firstTraces) = await translate(.codex, executable: codex)
    let (second, secondTraces) = await translate(.codex, executable: codex)
    #expect(try first.get() == "Hello")
    #expect(try second.get() == "Hello")
    #expect(firstTraces.contains { $0.contains("codex catalog 2 models prepared") })
    #expect(secondTraces.contains { $0.contains("codex catalog reused") })
    let debugRuns = try String(contentsOfFile: fakes.path("debug-count"), encoding: .utf8)
    #expect(debugRuns == "run\n", "debug models ran more than once")

    let debug = try fakes.recordedArguments("debug-args")
    #expect(Array(debug.prefix(2)) == ["debug", "models"])
    #expect(debug.contains("--bundled"), "catalog preparation must not refresh remotely")
    #expect(debug.values(of: "--disable") == CodexIsolation.disabledFeatures)

    let arguments = try fakes.recordedArguments("exec-args")
    #expect(arguments.first == "exec")
    for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"] {
      #expect(arguments.contains(flag), "missing \(flag)")
    }
    #expect(arguments.value(after: "--sandbox") == "read-only")
    let disabled = arguments.values(of: "--disable")
    for feature in ["goals", "tool_suggest", "sleep_tool", "shell_tool", "unified_exec", "apps",
                    "plugins", "hooks", "multi_agent", "multi_agent_v2", "browser_use", "image_generation",
                    "code_mode", "memories"] {
      #expect(disabled.contains(feature), "\(feature) not disabled")
    }
    #expect(arguments.values(of: "--enable") == ["skip_host_skill_discovery"])
    let config = arguments.values(of: "-c")
    for expected in [
      "project_doc_max_bytes=0", "developer_instructions=\"\"", "skills.bundled.enabled=false",
      "skills.include_instructions=false", "tools.update_plan.enabled=false",
      "tools.experimental_request_user_input.enabled=false", "web_search=\"disabled\"",
      "mcp_servers={}", "plugins={}", "include_apps_instructions=false",
      "include_collaboration_mode_instructions=false", "include_permissions_instructions=false",
      "include_environment_context=false", "model_reasoning_effort=\"low\"",
      "model_reasoning_summary=\"none\"", "model_verbosity=\"low\"",
    ] {
      #expect(config.contains(expected), "missing -c \(expected)")
    }
    // A blank model leaves the choice to the CLI's own default.
    #expect(!arguments.contains("--model"))
    #expect(arguments.last == PromptBuilder.userPrompt(text: Self.text, targetLanguage: "english"))

    func configPath(_ key: String) throws -> String {
      let entry = try #require(config.first { $0.hasPrefix("\(key)=") })
      return String(entry.dropFirst(key.count + 2).dropLast())
    }
    let instructions = try String(contentsOfFile: try configPath("model_instructions_file"), encoding: .utf8)
    #expect(instructions == PromptBuilder.systemPrompt)
    let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try configPath("model_catalog_json")))) as? [String: Any]
    let models = try #require(catalog?["models"] as? [[String: Any]])
    #expect(models.compactMap { $0["slug"] as? String } == ["fake-default", "fake-other"])
    #expect(models.allSatisfy { $0["tool_mode"] as? String == "direct" && $0["multi_agent_version"] is NSNull })

    try expectChildEnvironmentIsFiltered("exec-env")
    #expect(try String(contentsOfFile: fakes.path("exec-agents"), encoding: .utf8).isEmpty, "AGENTS.md was readable")
    #expect(try String(contentsOfFile: fakes.path("exec-notes"), encoding: .utf8) == "ordinary")
  }

  @Test func codexPassesAListedModel() async throws {
    let codex = try fakes.codexScript(exec: "printf 'Hello' > \"$out\"")
    let (result, _) = await translate(.codex, executable: codex, model: "fake-other")
    #expect(try result.get() == "Hello")
    #expect(try fakes.recordedArguments("exec-args").value(after: "--model") == "fake-other")
  }

  @Test func codexRefusesAModelItsCatalogDoesNotList() async throws {
    let codex = try fakes.codexScript(exec: "printf 'Hello' > \"$out\"")
    let (result, _) = await translate(.codex, executable: codex, model: "gpt-unknown")
    guard case .failure(TranslatorError.unknownModel(let model)) = result else {
      Issue.record("expected unknownModel, got \(result)")
      return
    }
    #expect(model == "gpt-unknown")
    #expect(!fakes.exists("exec-args"), "exec ran with an unlisted model")
  }

  @Test(arguments: [
    ("echo 'no catalog' >&2; exit 3", "processFailed(3)"),
    ("echo 'not json'", "isolationFailed"),
    (#"echo '{"models":[]}'"#, "isolationFailed"),
    (#"echo '{"models":[{"display_name":"no slug"}]}'"#, "isolationFailed"),
  ])
  func codexNeverRunsWhenTheCatalogCannotBePrepared(debug: String, summary: String) async throws {
    let codex = try fakes.codexScript(exec: "printf 'Hello' > \"$out\"", debug: debug)
    for _ in 0..<2 {
      let (result, _) = await translate(.codex, executable: codex)
      guard case .failure(let error as TranslatorError) = result else {
        Issue.record("expected a TranslatorError, got \(result)")
        return
      }
      #expect(error.logSummary == summary)
    }
    #expect(!fakes.exists("exec-args"), "exec ran without a sanitized catalog")
    // Failures aren't cached; each translation tries again.
    #expect(try String(contentsOfFile: fakes.path("debug-count"), encoding: .utf8) == "run\nrun\n")
  }

  @Test func preparingLeavesNothingBehindOnFailure() async throws {
    let parent = fakes.directory.appendingPathComponent("prepared", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let codex = try fakes.codexScript(exec: "", debug: "echo 'not json'")
    await #expect(throws: TranslatorError.self) {
      _ = try await CodexIsolation.prepare(executable: codex, in: parent) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
  }

  @Test func cancellingPreparationStopsTheCLIAndLeavesNothingBehind() async throws {
    let parent = fakes.directory.appendingPathComponent("prepared", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let codex = try fakes.codexScript(exec: "", debug: "echo $$ > '\(fakes.path("debug-pid"))'; sleep 30")
    let task = Task {
      try await CodexIsolation.prepare(executable: codex, in: parent) { _ in }
    }
    let pid = try await fakes.pid(in: "debug-pid")
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await FakeExecutables.exits(pid))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
  }

  @Test func sanitizedCatalogKeepsEveryModelAndStripsAgentMachinery() throws {
    let raw = Data(FakeExecutables.codexCatalog.utf8)
    let catalog = try CodexIsolation.sanitizedCatalog(raw, instructions: "Translate.")
    #expect(catalog.models == ["fake-default", "fake-other"])
    let root = try #require(try JSONSerialization.jsonObject(with: catalog.data) as? [String: Any])
    let models = try #require(root["models"] as? [[String: Any]])
    #expect(models.count == 2)
    for model in models {
      #expect(model["tool_mode"] as? String == "direct")
      #expect(model["model_messages"] is NSNull)
      #expect(model["apply_patch_tool_type"] is NSNull)
      #expect((model["experimental_supported_tools"] as? [Any])?.isEmpty == true)
      #expect(model["multi_agent_version"] is NSNull)
      #expect(model["include_skills_usage_instructions"] as? Bool == false)
      #expect(model["include_plugin_usage_instructions"] as? Bool == false)
      #expect(model["include_apps_usage_instructions"] as? Bool == false)
      #expect(model["base_instructions"] as? String == "Translate.")
    }
    // Everything else about a model stays as the CLI described it.
    #expect(models[0]["context_window"] as? Int == 1000)
    #expect(models[0]["priority"] as? Int == 1)
    #expect((models[0]["supported_reasoning_levels"] as? [[String: Any]])?.first?["effort"] as? String == "low")
    #expect(!String(decoding: catalog.data, as: UTF8.self).contains("AGENT"))
  }

  // MARK: Sandbox

  @Test func sandboxDeniesInstructionFilesButReadsOrdinaryText() async throws {
    let denied = ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "SKILL.md"]
    let allowed = ["notes.txt", "README.md", "MYAGENTS.md", "AGENTSxmd"]
    for name in denied + allowed {
      try "contents of \(name)".write(toFile: fakes.path(name), atomically: true, encoding: .utf8)
    }
    for name in denied + allowed {
      let command = try CLISandbox.command(
        executable: "/bin/cat",
        arguments: [fakes.path(name)],
        currentDirectory: fakes.directory.path,
        environment: ["PATH": "/usr/bin:/bin"]
      )
      let output = OutputLog()
      let exit = try await CLIProcess.run(command) { await output.append($0) }
      if denied.contains(name) {
        #expect(exit.status != 0, "\(name) was readable")
        #expect(await output.text.isEmpty)
      } else {
        #expect(exit.status == 0, "\(name) was denied")
        #expect(await output.text == "contents of \(name)")
      }
    }
  }

  @Test func missingSandboxFailsInsteadOfRunningUnrestricted() {
    #expect(throws: TranslatorError.self) {
      _ = try CLISandbox.command(
        executable: "/bin/cat",
        arguments: [],
        currentDirectory: "/",
        launcher: fakes.path("missing-sandbox-exec")
      )
    }
  }

  // MARK: Environment

  @Test func childEnvironmentKeepsOnlyRuntimeLocaleProxiesAndSignIn() {
    let kept = [
      "PATH": "/usr/bin:/bin",
      "TMPDIR": "/tmp/fake/",
      "LANG": "pt_BR.UTF-8",
      "LC_ALL": "pt_BR.UTF-8",
      "HTTPS_PROXY": "http://proxy.invalid:8080",
      "SSL_CERT_FILE": "/fake/cert.pem",
      "CODEX_HOME": "/fake/codex-home",
      "OPENAI_API_KEY": "fake-openai-key",
      "CLAUDE_CONFIG_DIR": "/fake/claude",
      "CLAUDE_CODE_OAUTH_TOKEN": "fake-oauth",
      "ANTHROPIC_API_KEY": "fake-anthropic-key",
    ]
    let dropped = [
      "CODEX_THREAD_ID": "fake-thread",
      "CODEX_SANDBOX": "seatbelt",
      "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
      "CODEX_TOOL_BRIDGE_SOCKET": "/fake/bridge.sock",
      "CLAUDECODE": "1",
      "CLAUDE_CODE_ENTRYPOINT": "cli",
      "CLAUDE_CODE_SSE_PORT": "1234",
      "AI_MEMORY_AUTH_TOKEN": "fake-memory-token",
      "MCP_SERVER_TOKEN": "fake-mcp-token",
      "SSH_AUTH_SOCK": "/fake/agent.sock",
      "NODE_OPTIONS": "--require /fake/inject.js",
      "BASH_ENV": "/fake/bashenv",
      "ZDOTDIR": "/fake/zdot",
      "PYTHONPATH": "/fake/py",
      "DYLD_INSERT_LIBRARIES": "/fake/inject.dylib",
    ]
    let env = ShellEnvironment.childEnvironment(
      from: kept.merging(dropped) { a, _ in a }.merging(["TERM": "xterm-256color"]) { a, _ in a }
    )
    for (name, value) in kept where name != "PATH" {
      #expect(env[name] == value, "\(name) not preserved")
    }
    for name in dropped.keys {
      #expect(env[name] == nil, "\(name) leaked")
    }
    #expect(env["TERM"] == "dumb")
    #expect(env["NO_COLOR"] == "1")
    #expect(env["HOME"] == NSHomeDirectory())
    let path = env["PATH"] ?? ""
    #expect(path.hasSuffix(":/usr/bin:/bin"))
    #expect(path.contains("/opt/homebrew/bin"))
  }
}
