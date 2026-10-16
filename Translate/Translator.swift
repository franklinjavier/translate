import Foundation
import os

nonisolated private let log = Logger(subsystem: "com.frank.translate", category: "translator")

nonisolated enum TranslatorError: LocalizedError, Sendable {
  case executableNotFound(String)
  case launchFailed(Int32)
  case emptyResponse
  case processFailed(status: Int32, stderr: String)
  case appleUnavailable(String)
  case localUnavailable(String)
  case isolationFailed(String)
  case unknownModel(String)

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let name):
      return "Couldn't find `\(name)`. Set the CLI path in Settings."
    case .launchFailed(let code):
      return "Couldn't start the CLI (\(String(cString: strerror(code))))."
    case .emptyResponse:
      return "The model returned an empty translation."
    case .processFailed(_, let stderr):
      let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Translation failed." : String(trimmed.suffix(280))
    case .appleUnavailable(let message):
      return message
    case .localUnavailable(let message):
      return message
    case .isolationFailed(let message):
      return message
    case .unknownModel(let model):
      return "The CLI doesn't list the model “\(model)”. Pick another in Settings, or leave it blank for the CLI's default."
    }
  }

  /// For logs: the kind and status only, never stderr or messages derived from the text.
  var logSummary: String {
    switch self {
    case .executableNotFound: "executableNotFound"
    case .launchFailed(let code): "launchFailed(\(code))"
    case .emptyResponse: "emptyResponse"
    case .processFailed(let status, _): "processFailed(\(status))"
    case .appleUnavailable: "appleUnavailable"
    case .localUnavailable: "localUnavailable"
    case .isolationFailed: "isolationFailed"
    case .unknownModel: "unknownModel"
    }
  }
}

/// The engine settings a translation started with. Captured when the shortcut is pressed,
/// so editing Settings mid-translation never changes the request in flight.
nonisolated struct EngineConfiguration: Sendable, Equatable {
  var engine: TranslationEngine
  var executableOverride: String
  var model: String
}

nonisolated struct Translator: Sendable {
  var configuration: EngineConfiguration

  /// `onOutput` receives diagnostic lines: lifecycle and counts only, never the text,
  /// prompts, CLI output or paths. The same lines go to the unified log.
  func translate(
    text: String,
    targetLanguage: String,
    onOutput: @escaping @Sendable (String) async -> Void,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let clock = DebugClock()
    let trace: @Sendable (String) async -> Void = { message in
      log.info("\(message, privacy: .public)")
      await onOutput(clock.line(message))
    }

    let raw: String
    switch configuration.engine {
    case .apple:
      // Apple only maps between languages and never falls back to a CLI or the local server.
      if AppleTranslation.isSameLanguage(text: text, targetLanguage: targetLanguage) {
        await trace("same language, Apple can't proofread")
        throw TranslatorError.appleUnavailable(AppleTranslation.cannotProofreadMessage)
      }
      raw = try await AppleTranslation.translate(
        text: text,
        targetLanguage: targetLanguage,
        onOutput: onOutput,
        onPartial: onPartial
      )
    case .local:
      raw = try await LocalMLX.translate(
        text: text,
        targetLanguage: targetLanguage,
        model: configuration.model,
        onPartial: onPartial,
        trace: trace
      )
    case .claude, .codex:
      raw = try await runCLI(text: text, targetLanguage: targetLanguage, onPartial: onPartial, trace: trace)
    }

    let cleaned = OutputSanitizer.sanitize(raw)
    if cleaned.count != raw.count {
      await trace("sanitize \(raw.count) → \(cleaned.count) chars")
    }
    guard !cleaned.isEmpty else {
      await trace("empty after sanitize")
      throw TranslatorError.emptyResponse
    }
    await trace("done \(cleaned.count) chars, \(clock.rate(characters: cleaned.count))")
    return cleaned
  }

  private func runCLI(
    text: String,
    targetLanguage: String,
    onPartial: @escaping @Sendable (String) async -> Void,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let engine = configuration.engine
    await trace("\(engine.title) CLI, source \(text.count) chars")
    let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    await trace(model.isEmpty ? "model=(default)" : "model=\(model)")

    let name = engine.executableName
    guard let executable = ShellEnvironment.resolveExecutable(
      named: name,
      override: configuration.executableOverride
    ) else {
      await trace("executable not found")
      throw TranslatorError.executableNotFound(name)
    }

    let user = PromptBuilder.userPrompt(text: text, targetLanguage: targetLanguage)
    if engine == .claude {
      return try await runClaude(executable: executable, model: model, user: user, onPartial: onPartial, trace: trace)
    }
    return try await runCodex(executable: executable, model: model, user: user, trace: trace)
  }

  /// Claude streams stream-json only to a terminal, so stdout is a PTY. No tools, MCP
  /// servers, settings files, skills, plugins, hooks or CLAUDE.md: the system prompt and the
  /// text are the app's inputs; the CLI may add fixed SDK metadata. `--bare` can't use a subscription login.
  private func runClaude(
    executable: String,
    model: String,
    user: String,
    onPartial: @escaping @Sendable (String) async -> Void,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    var arguments = [
      "-p",
      "--output-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--tools", "",
      "--strict-mcp-config",
      "--mcp-config", #"{"mcpServers":{}}"#,
      "--setting-sources", "",
      "--no-session-persistence",
      "--disable-slash-commands",
      "--safe-mode",
      "--effort", "low",
      "--permission-mode", "dontAsk",
      "--system-prompt", PromptBuilder.systemPrompt,
    ]
    if !model.isEmpty {
      arguments += ["--model", model]
    }
    arguments.append(user)

    let parser = ClaudeStreamConsumer(onPartial: onPartial, trace: trace)
    let exit = try await run(
      executable: executable,
      arguments: arguments,
      directory: NSTemporaryDirectory(),
      terminal: true,
      trace: trace
    ) { chunk in
      await parser.consume(chunk)
    }
    let result = await parser.finish()
    try check(exit)
    if result.isError {
      // An auth or quota report from the CLI, shown as the error rather than as a translation.
      throw TranslatorError.processFailed(status: exit.status, stderr: result.text)
    }
    return result.text
  }

  /// Codex's stdout is progress, never the translation: the popover keeps loading until the
  /// final message file is written. The system prompt goes in as the model instructions,
  /// replacing Codex's agent instructions; see `CodexIsolation`.
  private func runCodex(
    executable: String,
    model: String,
    user: String,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let prepared: PreparedCodex
    do {
      prepared = try await CodexPreparations.shared.prepared(executable: executable, trace: trace)
    } catch is CancellationError {
      await trace("cancelled while preparing")
      throw CancellationError()
    }
    // Only a model the CLI lists runs with the sanitized catalog; anything else would get
    // Codex's generic agent setup.
    if !model.isEmpty, !prepared.models.contains(model) {
      await trace("model not in codex catalog")
      throw TranslatorError.unknownModel(model)
    }

    let workspace = prepared.directory.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let messageFile = workspace.appendingPathComponent("last-message.txt")

    let exit = try await run(
      executable: executable,
      arguments: CodexIsolation.execArguments(prepared, model: model, messageFile: messageFile.path, prompt: user),
      directory: workspace.path,
      terminal: false,
      trace: trace
    ) { _ in }
    try check(exit)
    let raw = (try? String(contentsOf: messageFile, encoding: .utf8)) ?? ""
    await trace("last message \(raw.count) chars")
    return raw
  }

  private func run(
    executable: String,
    arguments: [String],
    directory: String,
    terminal: Bool,
    trace: @escaping @Sendable (String) async -> Void,
    onStdout: @escaping @Sendable (String) async -> Void
  ) async throws -> CLIExit {
    let command = try CLISandbox.command(
      executable: executable,
      arguments: arguments,
      currentDirectory: directory,
      stdoutIsTerminal: terminal
    )
    await trace(terminal ? "spawn sandboxed, stdout=pty" : "spawn sandboxed")
    do {
      let exit = try await CLIProcess.run(command, onStdout: onStdout)
      await trace("exit \(exit.status), stdout \(exit.stdoutBytes) bytes, stderr \(exit.stderrBytes) bytes")
      return exit
    } catch is CancellationError {
      await trace("cancelled, process stopped")
      throw CancellationError()
    }
  }

  private func check(_ exit: CLIExit) throws {
    guard exit.status == 0 else {
      throw TranslatorError.processFailed(status: exit.status, stderr: exit.stderr)
    }
  }
}

/// Feeds CLI stdout to the stream-json parser in arrival order and forwards what it displays.
private actor ClaudeStreamConsumer {
  private var parser = ClaudeStreamParser()
  private let onPartial: @Sendable (String) async -> Void
  private let trace: @Sendable (String) async -> Void

  init(onPartial: @escaping @Sendable (String) async -> Void, trace: @escaping @Sendable (String) async -> Void) {
    self.onPartial = onPartial
    self.trace = trace
  }

  func consume(_ chunk: String) async {
    await deliver(parser.consume(chunk))
  }

  func finish() async -> (text: String, isError: Bool) {
    await deliver(parser.finish())
    return (parser.finalText, parser.resultIsError)
  }

  private func deliver(_ pulse: ClaudeStreamPulse) async {
    for line in pulse.traces {
      await trace(line)
    }
    if let displayed = pulse.displayed, !displayed.isEmpty {
      await onPartial(displayed)
    }
  }
}
