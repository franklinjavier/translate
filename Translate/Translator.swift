import Foundation
import Darwin
import os

nonisolated private let log = Logger(subsystem: "com.frank.translate", category: "translator")

nonisolated enum TranslatorError: LocalizedError, Sendable {
  case executableNotFound(String)
  case emptyResponse
  case processFailed(status: Int32, stderr: String)
  case appleUnavailable(String)
  case localUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let name):
      return "Couldn't find `\(name)`. Set the CLI path in Settings."
    case .emptyResponse:
      return "The model returned an empty translation."
    case .processFailed(_, let stderr):
      let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Translation failed." : String(trimmed.prefix(280))
    case .appleUnavailable(let message):
      return message
    case .localUnavailable(let message):
      return message
    }
  }
}

nonisolated struct Translator: Sendable {
  var backend: LLMBackend
  var executableOverride: String
  var model: String
  var useAppleOnDeviceModel: Bool

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

    if useAppleOnDeviceModel {
      let raw = try await AppleTranslation.translate(
        text: text,
        targetLanguage: targetLanguage,
        onOutput: onOutput,
        onPartial: onPartial
      )
      let cleaned = OutputSanitizer.sanitize(raw)
      guard !cleaned.isEmpty else { throw TranslatorError.emptyResponse }
      return cleaned
    }

    if backend == .local {
      let raw = try await LocalMLX.translate(
        text: text,
        targetLanguage: targetLanguage,
        model: model,
        onPartial: onPartial,
        trace: trace
      )
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

    await trace("\(backend.title) CLI")
    await trace("source \(text.count) chars → \(targetLanguage)")
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedModel.isEmpty {
      await trace("model=(default)")
    } else {
      await trace("model=\(trimmedModel)")
    }

    let executableName = backend.defaultExecutableName
    guard let executable = ShellEnvironment.resolveExecutable(
      named: executableName,
      override: executableOverride
    ) else {
      await trace("executable not found: \(executableName)")
      throw TranslatorError.executableNotFound(executableName)
    }
    await trace("executable=\(executable)")

    let raw: String
    switch backend {
    case .local:
      throw TranslatorError.localUnavailable("Local MLX should not spawn a CLI.")
    case .claude:
      raw = try await runClaude(
        executable: executable,
        model: model,
        system: PromptBuilder.systemPrompt,
        user: PromptBuilder.userPrompt(text: text, targetLanguage: targetLanguage),
        onPartial: onPartial,
        trace: trace
      )
    case .codex:
      raw = try await runCodex(
        executable: executable,
        model: model,
        prompt: """
          \(PromptBuilder.systemPrompt)

          \(PromptBuilder.userPrompt(text: text, targetLanguage: targetLanguage))
          """,
        onPartial: onPartial,
        trace: trace
      )
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

  @concurrent
  private func runClaude(
    executable: String,
    model: String,
    system: String,
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
      "--no-session-persistence",
      "--disable-slash-commands",
      "--safe-mode",
      "--effort", "low",
      "--permission-mode", "dontAsk",
      "--system-prompt", system,
    ]
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedModel.isEmpty {
      arguments += ["--model", trimmedModel]
    }
    arguments.append(user)
    await trace("format=stream-json +partials")
    await trace("args=\(arguments.dropLast().joined(separator: " "))")
    return try await runProcess(
      executable: executable,
      arguments: arguments,
      onPartial: onPartial,
      trace: trace,
      stdoutMode: .claudeStream,
      ttyStdout: true
    )
  }

  @concurrent
  private func runCodex(
    executable: String,
    model: String,
    prompt: String,
    onPartial: @escaping @Sendable (String) async -> Void,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let messageFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("translate-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: messageFile) }

    var arguments = [
      "exec",
      "--skip-git-repo-check",
      "--ephemeral",
      "--sandbox", "read-only",
      "--color", "never",
      "--output-last-message", messageFile.path,
    ]
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedModel.isEmpty {
      arguments += ["--model", trimmedModel]
    }
    arguments.append(prompt)

    _ = try await runProcess(
      executable: executable,
      arguments: arguments,
      onPartial: onPartial,
      trace: trace,
      stdoutMode: .raw,
      ttyStdout: false
    )
    let raw = (try? String(contentsOf: messageFile, encoding: .utf8)) ?? ""
    await trace("last-message \(raw.count) chars")
    if !raw.isEmpty {
      await onPartial(raw)
    }
    return raw
  }

  @concurrent
  private func runProcess(
    executable: String,
    arguments: [String],
    onPartial: @escaping @Sendable (String) async -> Void,
    trace: @escaping @Sendable (String) async -> Void,
    stdoutMode: OutputCollector.StdoutMode,
    ttyStdout: Bool
  ) async throws -> String {
    await trace("spawn")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ShellEnvironment.processEnvironment()
    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    process.standardInput = FileHandle.nullDevice

    let stdoutRead: FileHandle
    var slaveToClose: FileHandle?
    if ttyStdout {
      let pair = try PseudoTerminal.makePair()
      process.standardOutput = pair.slave
      stdoutRead = pair.master
      slaveToClose = pair.slave
      await trace("stdout=pty")
    } else {
      let stdout = Pipe()
      process.standardOutput = stdout
      stdoutRead = stdout.fileHandleForReading
    }

    let stderr = Pipe()
    process.standardError = stderr

    let collected = OutputCollector(stdoutMode: stdoutMode)
    stdoutRead.readabilityHandler = { handle in
      collected.consume(handle.availableData, stream: .out, onPartial: onPartial, trace: trace)
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      collected.consume(handle.availableData, stream: .err, onPartial: nil, trace: trace)
    }

    try process.run()
    if let slaveToClose {
      try slaveToClose.close()
    }
    await trace("pid=\(process.processIdentifier)")

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in
        continuation.resume()
      }
    }

    stdoutRead.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    collected.consume(
      stdoutRead.readDataToEndOfFile(),
      stream: .out,
      onPartial: onPartial,
      trace: trace
    )
    collected.consume(
      stderr.fileHandleForReading.readDataToEndOfFile(),
      stream: .err,
      onPartial: nil,
      trace: trace
    )
    collected.finish(onPartial: onPartial, trace: trace)
    await collected.drain()

    if Task.isCancelled {
      throw CancellationError()
    }

    let output = collected.stdout
    let errorOutput = collected.stderr

    guard process.terminationStatus == 0 else {
      await trace("exit \(process.terminationStatus)")
      log.error("Process failed with status \(process.terminationStatus)")
      throw TranslatorError.processFailed(status: process.terminationStatus, stderr: errorOutput)
    }

    await trace("exit 0, text \(output.count) chars")
    return output
  }
}

nonisolated private final class OutputCollector: @unchecked Sendable {
  enum Stream {
    case out
    case err
  }

  enum StdoutMode {
    case raw
    case claudeStream
  }

  private let lock = NSLock()
  private let stdoutMode: StdoutMode
  private var rawStdout = ""
  private(set) var stderr = ""
  private var stdoutChunks = 0
  private var leftoverOut = Data()
  private var leftoverErr = Data()
  private var parser = ClaudeStreamParser()
  private var pending = Task<Void, Never> {}

  init(stdoutMode: StdoutMode) {
    self.stdoutMode = stdoutMode
  }

  var stdout: String {
    lock.lock()
    defer { lock.unlock() }
    switch stdoutMode {
    case .raw:
      return rawStdout
    case .claudeStream:
      return parser.finalText
    }
  }

  func consume(
    _ data: Data,
    stream: Stream,
    onPartial: (@Sendable (String) async -> Void)?,
    trace: @escaping @Sendable (String) async -> Void
  ) {
    guard !data.isEmpty else { return }
    lock.lock()
    let chunk: String
    switch stream {
    case .out:
      chunk = Self.decodeUTF8(data, leftover: &leftoverOut)
    case .err:
      chunk = Self.decodeUTF8(data, leftover: &leftoverErr)
    }
    guard !chunk.isEmpty else {
      lock.unlock()
      return
    }
    let pulse: ClaudeStreamPulse
    switch stream {
    case .out:
      rawStdout += chunk
      stdoutChunks += 1
      let chunkIndex = stdoutChunks
      switch stdoutMode {
      case .raw:
        pulse = ClaudeStreamPulse(displayed: rawStdout, traces: [
          "stdout #\(chunkIndex) +\(chunk.count) total=\(rawStdout.count) \(Self.preview(chunk))",
        ])
      case .claudeStream:
        pulse = parser.consume(chunk)
      }
    case .err:
      stderr += chunk
      pulse = ClaudeStreamPulse(traces: [
        "stderr +\(chunk.count) \(Self.preview(chunk, limit: 120))",
      ])
    }
    lock.unlock()
    enqueue {
      for line in pulse.traces {
        await trace(line)
      }
      if stream == .out, let onPartial, let displayed = pulse.displayed, !displayed.isEmpty {
        await onPartial(displayed)
      }
    }
  }

  func finish(
    onPartial: @escaping @Sendable (String) async -> Void,
    trace: @escaping @Sendable (String) async -> Void
  ) {
    lock.lock()
    let pulse: ClaudeStreamPulse
    switch stdoutMode {
    case .raw:
      pulse = ClaudeStreamPulse()
    case .claudeStream:
      pulse = parser.finish()
    }
    lock.unlock()
    enqueue {
      for line in pulse.traces {
        await trace(line)
      }
      if let displayed = pulse.displayed, !displayed.isEmpty {
        await onPartial(displayed)
      }
    }
  }

  func drain() async {
    await snapshotPending().value
  }

  private func snapshotPending() -> Task<Void, Never> {
    lock.lock()
    let task = pending
    lock.unlock()
    return task
  }

  private func enqueue(_ work: @escaping @Sendable () async -> Void) {
    lock.lock()
    let previous = pending
    pending = Task {
      await previous.value
      await work()
    }
    lock.unlock()
  }

  private static func decodeUTF8(_ data: Data, leftover: inout Data) -> String {
    leftover.append(data)
    if let text = String(data: leftover, encoding: .utf8) {
      leftover.removeAll(keepingCapacity: true)
      return text
    }
    var end = leftover.count
    let floor = max(0, leftover.count - 4)
    while end > floor {
      end -= 1
      if let text = String(data: leftover.prefix(end), encoding: .utf8) {
        leftover.removeFirst(end)
        return text
      }
    }
    return ""
  }

  private static func preview(_ text: String, limit: Int = 48) -> String {
    let collapsed = text
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\t", with: "\\t")
    if collapsed.count <= limit {
      return "“\(collapsed)”"
    }
    return "“\(collapsed.prefix(limit))…”"
  }
}

nonisolated enum PseudoTerminal {
  static func makePair() throws -> (master: FileHandle, slave: FileHandle) {
    let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
    guard masterFD >= 0 else {
      throw TranslatorError.processFailed(status: -1, stderr: "Couldn't open a PTY.")
    }
    guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0 else {
      close(masterFD)
      throw TranslatorError.processFailed(status: -1, stderr: "Couldn't unlock PTY.")
    }

    var name = [CChar](repeating: 0, count: Int(PATH_MAX))
    let named = name.withUnsafeMutableBufferPointer { buffer in
      ptsname_r(masterFD, buffer.baseAddress, buffer.count) == 0
    }
    guard named else {
      close(masterFD)
      throw TranslatorError.processFailed(status: -1, stderr: "Couldn't name PTY.")
    }

    let path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard let slave = FileHandle(forUpdatingAtPath: path) else {
      close(masterFD)
      throw TranslatorError.processFailed(status: -1, stderr: "Couldn't open PTY slave.")
    }
    let slaveFD = slave.fileDescriptor

    var window = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(masterFD, UInt(TIOCSWINSZ), &window)

    var term = termios()
    if tcgetattr(slaveFD, &term) == 0 {
      cfmakeraw(&term)
      _ = tcsetattr(slaveFD, TCSANOW, &term)
    }

    return (
      FileHandle(fileDescriptor: masterFD, closeOnDealloc: true),
      slave
    )
  }
}
