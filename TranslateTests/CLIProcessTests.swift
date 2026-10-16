import Darwin
import Foundation
import Testing
@testable import Translate

/// Shell scripts standing in for the Claude and Codex CLIs, in a fresh directory per test.
nonisolated struct FakeExecutables: Sendable {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("translate-fake-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func script(_ body: String, name: String = "fake") throws -> String {
    let url = directory.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  func path(_ name: String) -> String {
    directory.appendingPathComponent(name).path
  }

  /// Called once the suite's processes have exited; every test awaits its process first.
  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func command(_ executable: String, _ arguments: [String] = [], terminal: Bool = false) -> CLICommand {
    CLICommand(
      executable: executable,
      arguments: arguments,
      environment: ["PATH": "/usr/bin:/bin"],
      currentDirectory: directory.path,
      stdoutIsTerminal: terminal
    )
  }

  func pid(in file: String) async throws -> pid_t {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let text = try? String(contentsOfFile: path(file), encoding: .utf8),
         let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return pid
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw EventuallyTimeout()
  }

  static func isRunning(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  /// Orphaned grandchildren are reaped by launchd, so allow a moment after the kill.
  static func exits(_ pid: pid_t) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while isRunning(pid), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return !isRunning(pid)
  }
}

/// Collects stdout chunks in the order the executor delivered them.
actor OutputLog {
  private(set) var chunks: [String] = []
  func append(_ chunk: String) { chunks.append(chunk) }
  var text: String { chunks.joined() }
}

nonisolated final class CLIProcessTests {
  let fakes: FakeExecutables

  init() throws {
    fakes = try FakeExecutables()
  }

  deinit {
    fakes.remove()
  }

  @Test func immediateExitWithNoOutput() async throws {
    let exit = try await CLIProcess.run(fakes.command(fakes.script("exit 0"))) { _ in }
    #expect(exit == CLIExit(status: 0, stderr: "", stdoutBytes: 0, stderrBytes: 0))
  }

  @Test func nonzeroExitKeepsStatusAndStderr() async throws {
    let exit = try await CLIProcess.run(fakes.command(fakes.script("echo oops >&2; exit 3"))) { _ in }
    #expect(exit.status == 3)
    #expect(exit.stderr == "oops\n")
  }

  @Test func invalidExecutableFailsToLaunch() async throws {
    await #expect(throws: TranslatorError.self) {
      _ = try await CLIProcess.run(fakes.command(fakes.path("missing"))) { _ in }
    }
    let notExecutable = fakes.path("plain")
    try "echo hi".write(toFile: notExecutable, atomically: true, encoding: .utf8)
    await #expect(throws: TranslatorError.self) {
      _ = try await CLIProcess.run(fakes.command(notExecutable)) { _ in }
    }
  }

  @Test func cancellationBeforeLaunchStartsNothing() async throws {
    let marker = fakes.path("started")
    let command = fakes.command(try fakes.script("touch \"$1\""), [marker])
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await CLIProcess.run(command) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  @Test func cancellationStopsTheProcessAndItsChildren() async throws {
    let script = try fakes.script("""
      sleep 30 &
      echo $! > "$2"
      echo $$ > "$1"
      wait
      """)
    let command = fakes.command(script, [fakes.path("pid"), fakes.path("child")])
    let task = Task { try await CLIProcess.run(command) { _ in } }
    let pid = try await fakes.pid(in: "pid")
    let child = try await fakes.pid(in: "child")
    let started = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(!FakeExecutables.isRunning(pid))
    #expect(await FakeExecutables.exits(child))
  }

  @Test func ignoredSIGTERMEscalatesWithinABound() async throws {
    let script = try fakes.script("""
      trap '' TERM
      echo $$ > "$1"
      while :; do sleep 0.05; done
      """)
    let command = fakes.command(script, [fakes.path("pid")])
    let task = Task { try await CLIProcess.run(command) { _ in } }
    let pid = try await fakes.pid(in: "pid")
    let started = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed >= .milliseconds(700), "SIGTERM was ignored, so only SIGKILL ends it")
    #expect(elapsed < .seconds(3))
    #expect(!FakeExecutables.isRunning(pid))
  }

  /// A background child inherits stdout and would keep it open for 30 s.
  @Test func childHoldingThePipeOpenCannotStallCompletion() async throws {
    let script = try fakes.script("""
      sleep 30 &
      echo $! > "$1"
      echo started
      exit 0
      """)
    let log = OutputLog()
    let started = ContinuousClock.now
    let exit = try await CLIProcess.run(fakes.command(script, [fakes.path("child")])) { await log.append($0) }
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(exit.status == 0)
    #expect(await log.text == "started\n")
    #expect(await FakeExecutables.exits(try await fakes.pid(in: "child")))
  }

  @Test func burstOfStdoutAndStderrArrivesCompleteAndInOrder() async throws {
    let script = try fakes.script("""
      i=0
      while [ $i -lt 3000 ]; do
        echo "line $i"
        echo "err $i" >&2
        i=$((i+1))
      done
      """)
    let log = OutputLog()
    let exit = try await CLIProcess.run(fakes.command(script)) { await log.append($0) }
    let expected = (0..<3000).map { "line \($0)\n" }.joined()
    #expect(await log.text == expected)
    #expect(exit.stdoutBytes == expected.utf8.count)
    #expect(exit.stderrBytes == (0..<3000).map { "err \($0)\n" }.joined().utf8.count)
    #expect(exit.stderr.utf8.count <= CLIProcess.stderrLimit)
    #expect(exit.stderr.hasSuffix("err 2999\n"))
  }

  @Test func unicodeSplitAcrossWritesIsDecodedWhole() async throws {
    let script = try fakes.script(#"""
      printf '\303'; sleep 0.05
      printf '\251 \360\237'; sleep 0.05
      printf '\221\213\n'
      """#)
    let log = OutputLog()
    _ = try await CLIProcess.run(fakes.command(script)) { await log.append($0) }
    #expect(await log.text == "é 👋\n")
    #expect(await !log.chunks.contains { $0.contains("\u{FFFD}") })
  }

  @Test(arguments: [true, false])
  func stdoutIsATerminalOnlyWhenAsked(terminal: Bool) async throws {
    let script = try fakes.script("if [ -t 1 ]; then echo tty; else echo pipe; fi")
    let log = OutputLog()
    _ = try await CLIProcess.run(fakes.command(script, terminal: terminal)) { await log.append($0) }
    #expect(await log.text == (terminal ? "tty\n" : "pipe\n"))
  }
}

nonisolated struct UTF8StreamDecoderTests {
  @Test func everySplitPointDecodesTheSameText() {
    let text = "Tradução 👋🏽 café — ok"
    let bytes = Array(text.utf8)
    for cut in 0...bytes.count {
      var decoder = UTF8StreamDecoder()
      let joined = decoder.decode(Data(bytes[..<cut])) + decoder.decode(Data(bytes[cut...])) + decoder.finish()
      #expect(joined == text, "split at \(cut)")
    }
  }

  @Test func byteAtATime() {
    let text = "日本語 ✓"
    var decoder = UTF8StreamDecoder()
    var joined = ""
    for byte in text.utf8 {
      let piece = decoder.decode(Data([byte]))
      #expect(!piece.contains("\u{FFFD}"))
      joined += piece
    }
    #expect(joined + decoder.finish() == text)
  }

  @Test func truncatedSequenceAtEOFIsReplacedNotDropped() {
    var decoder = UTF8StreamDecoder()
    #expect(decoder.decode(Data([0x61, 0xE2, 0x9C])) == "a")
    #expect(decoder.finish() == "\u{FFFD}")
  }
}
