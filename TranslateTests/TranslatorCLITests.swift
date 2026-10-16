import Foundation
import Testing
@testable import Translate

/// The real `Translator` against fake CLIs: what reaches the popover, and that diagnostics
/// never carry the text, CLI output or paths.
nonisolated final class TranslatorCLITests {
  static let sentinel = "ZQX-SENTINEL-7781"
  let fakes: FakeExecutables

  init() throws {
    fakes = try FakeExecutables()
  }

  deinit {
    fakes.remove()
  }

  struct Run {
    var result: Result<String, Error>
    var traces: [String]
    var partials: [String]
  }

  func translate(engine: TranslationEngine, script: String) async throws -> Run {
    let executable = engine == .codex
      ? try fakes.codexScript(exec: script)
      : try fakes.script(script, name: engine.executableName)
    let translator = Translator(configuration: EngineConfiguration(engine: engine, executableOverride: executable, model: ""))
    let traces = OutputLog()
    let partials = OutputLog()
    let result: Result<String, Error>
    do {
      result = .success(try await translator.translate(
        text: "segredo \(Self.sentinel)",
        targetLanguage: "english",
        onOutput: { await traces.append($0) },
        onPartial: { await partials.append($0) }
      ))
    } catch {
      result = .failure(error)
    }
    return Run(result: result, traces: await traces.chunks, partials: await partials.chunks)
  }

  func expectNoContent(in traces: [String]) {
    #expect(!traces.isEmpty)
    for line in traces {
      #expect(!line.contains(Self.sentinel), "trace leaks content: \(line)")
      #expect(!line.contains(fakes.directory.path), "trace leaks a path: \(line)")
      #expect(!line.contains("--system-prompt"), "trace leaks arguments: \(line)")
    }
  }

  @Test func claudeStreamsDeltasAndTracesOnlyCounts() async throws {
    let run = try await translate(engine: .claude, script: """
      echo "stderr \(Self.sentinel)" >&2
      printf '%s\\n' '{"type":"system","subtype":"init","cwd":"\(Self.sentinel)"}'
      printf '%s\\n' '{"type":"\(Self.sentinel)"}'
      printf '%s\\n' '{"type":"stream_event","event":{"type":"\(Self.sentinel)"}}'
      printf '%s\\n' 'not json \(Self.sentinel)'
      printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi "}}}'
      printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\(Self.sentinel)"}}}'
      printf '%s\\n' '{"type":"result","subtype":"success","result":"Hi \(Self.sentinel)"}'
      """)
    #expect(try run.result.get() == "Hi \(Self.sentinel)")
    // Chunking decides how many partials arrive; each extends the last.
    #expect(run.partials.last == "Hi \(Self.sentinel)")
    #expect(zip(run.partials, run.partials.dropFirst()).allSatisfy { $1.hasPrefix($0) })
    expectNoContent(in: run.traces)
  }

  @Test func claudeErrorResultIsNotATranslation() async throws {
    let run = try await translate(engine: .claude, script: """
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key"}'
      """)
    #expect(throws: TranslatorError.self) { try run.result.get() }
    #expect(run.partials.isEmpty)
  }

  /// Codex prints progress on stdout; only the final message file is the translation.
  @Test func codexStdoutNeverReachesThePopover() async throws {
    let run = try await translate(engine: .codex, script: """
      echo "progress \(Self.sentinel)"
      echo "thinking \(Self.sentinel)" >&2
      printf 'Olá \(Self.sentinel)' > "$out"
      """)
    #expect(try run.result.get() == "Olá \(Self.sentinel)")
    #expect(run.partials.isEmpty)
    expectNoContent(in: run.traces)
  }

  @Test func failingCLIShowsStderrButNeverLogsIt() async throws {
    let run = try await translate(engine: .claude, script: """
      echo "auth failed \(Self.sentinel)" >&2
      exit 2
      """)
    guard case .failure(let error as TranslatorError) = run.result else {
      Issue.record("expected a TranslatorError, got \(run.result)")
      return
    }
    #expect(error.logSummary == "processFailed(2)")
    #expect(error.localizedDescription.contains("auth failed"))
    expectNoContent(in: run.traces)
  }
}
