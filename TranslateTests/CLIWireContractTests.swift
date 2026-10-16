import Foundation
import Testing
@testable import Translate

/// Opt-in: drives the real Translator and installed CLIs against loopback-only fake model
/// endpoints. It sends no translation to a real model and inspects no credential files.
@Suite(.serialized, .enabled(
  if: ProcessInfo.processInfo.environment["TRANSLATION_CLI_CONTRACT_TESTS"] == "1",
  "Set TEST_RUNNER_TRANSLATION_CLI_CONTRACT_TESTS=1 to check installed CLI payloads"
))
struct CLIWireContractTests {
  @Test(.timeLimit(.minutes(1)), arguments: [TranslationEngine.claude, .codex])
  func installedCLIHasNoToolsOrExternalInstructions(engine: TranslationEngine) async throws {
    let cli = try #require(ShellEnvironment.resolveExecutable(named: engine.executableName, override: ""))
    let fixtures = try FakeExecutables()
    defer { fixtures.remove() }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/cli-wire-server.py")
    server.arguments = ["-I", helper.path, fixtures.directory.path]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
      server.terminate()
      server.waitUntilExit()
    }
    let portFile = fixtures.directory.appendingPathComponent("port.txt")
    try await eventually { FileManager.default.fileExists(atPath: portFile.path) }
    let port = try String(contentsOf: portFile, encoding: .utf8)
    let endpoint = "http://127.0.0.1:\(port)"
    let wrapper: String
    if engine == .codex {
      wrapper = """
        for argument do
          if [ "$argument" = debug ]; then exec \(shellQuote(cli)) "$@"; fi
        done
        exec \(shellQuote(cli)) "$@" \
          -c 'model_provider="translation_contract"' \
          -c 'model_providers.translation_contract.name="Loopback contract test"' \
          -c 'model_providers.translation_contract.base_url="\(endpoint)/v1"' \
          -c 'model_providers.translation_contract.wire_api="responses"' \
          -c 'model_providers.translation_contract.requires_openai_auth=false'
        """
    } else {
      wrapper = """
        export ANTHROPIC_API_KEY=local-contract-test-not-a-real-key
        export ANTHROPIC_BASE_URL=\(shellQuote(endpoint))
        export DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
        exec \(shellQuote(cli)) "$@"
        """
    }
    let executable = try fixtures.script(wrapper, name: engine.executableName)
    let translator = Translator(configuration: EngineConfiguration(
      engine: engine, executableOverride: executable, model: engine == .codex ? "gpt-6-sol" : "haiku"
    ))
    let translated = try await translator.translate(
      text: "oi", targetLanguage: "english", onOutput: { _ in }, onPartial: { _ in }
    )
    #expect(translated == "Hi.")
    let raw = try Data(contentsOf: fixtures.directory.appendingPathComponent("request.json"))
    let request = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    #expect((request["tools"] as? [Any] ?? []).isEmpty)
    for input in request["input"] as? [[String: Any]] ?? [] where input["type"] as? String == "additional_tools" {
      #expect((input["tools"] as? [Any] ?? []).isEmpty)
    }
    let expectedUser = PromptBuilder.userPrompt(text: "oi", targetLanguage: "english")
    if engine == .codex {
      let texts = (request["input"] as? [[String: Any]] ?? []).flatMap { input in
        (input["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
      }
      #expect(texts == [PromptBuilder.systemPrompt, expectedUser])
    } else {
      let system = request["system"] as? [[String: Any]] ?? []
      #expect(system.contains { $0["text"] as? String == PromptBuilder.systemPrompt })
      let userMessages = (request["messages"] as? [[String: Any]] ?? [])
        .filter { $0["role"] as? String == "user" }
      #expect(userMessages.count == 1)
      #expect(userMessages.first?["content"] as? String == expectedUser)
    }
    let payload = String(decoding: raw, as: UTF8.self)
    for forbidden in ["# AGENTS.md instructions", "<skills_instructions>", "<multi_agent_role>", "<multi_agent_mode>"] {
      #expect(!payload.contains(forbidden), "unexpected CLI context: \(forbidden)")
    }
    #expect(payload.contains("oi"))
  }
}

private func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
