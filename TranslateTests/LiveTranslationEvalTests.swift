import CryptoKit
import Foundation
import NaturalLanguage
import Testing
@testable import Translate

// MARK: - Live translation eval

/// Opt-in quality eval: the real `Translator`, prompt, sanitizer, and default engine. No mocks.
/// How to run, compare, and score by hand: docs/translation-eval.md.
///
///     TEST_RUNNER_TRANSLATION_LIVE_TESTS=1 \
///     TEST_RUNNER_TRANSLATION_LIVE_RESULTS=/tmp/translate-eval/after.jsonl \
///     xcodebuild test -scheme Translate -destination 'platform=macOS,arch=arm64' \
///       -only-testing:TranslateTests/LiveTranslationEvalTests
///
/// Once opted in, an unreachable engine fails every case instead of skipping.
@Suite(.serialized, .enabled(if: LiveEval.isEnabled, "Set TEST_RUNNER_TRANSLATION_LIVE_TESTS=1"))
struct LiveTranslationEvalTests {
  @Test(.timeLimit(.minutes(3)), arguments: LiveEval.cases)
  func translates(_ evalCase: LiveCase) async throws {
    let result = await LiveEval.run(evalCase)
    print(result.summary)
    try LiveEval.record(result)
    if let error = result.error {
      Issue.record("\(evalCase.id): \(error)")
    }
    for failure in result.failures {
      Issue.record("\(evalCase.id): \(failure)")
    }
  }
}

/// Runs the eval's checks against hand-written outputs, so they accept natural variants
/// and still catch known regressions. No engine needed.
struct LiveEvalCaseTests {
  @Test func coversTheRequiredScenarios() {
    let cases = LiveEval.cases
    #expect(cases.count >= 20)
    #expect(Set(cases.map(\.id)).count == cases.count)
    for direction in LiveCase.Direction.allCases {
      #expect(cases.filter { $0.direction == direction }.count >= 6, "\(direction.rawValue)")
    }
    for id in ["en-proof-like-baby", "pt-en-like-baby", "en-pt-like-baby"] {
      #expect(cases.contains { $0.id == id }, "missing \(id)")
    }
  }

  @Test func targetsMatchDefaultSettings() {
    #expect(LiveCase.Direction.proofreadEnglish.targetLanguage == TranslationTarget.english.language)
    #expect(LiveCase.Direction.portugueseToEnglish.targetLanguage == TranslationTarget.english.language)
    #expect(LiveCase.Direction.englishToPortuguese.targetLanguage == TranslationTarget.portuguese.language)
    #expect(AppSettings.default.engine == .local)
  }

  @Test func patternsCompile() {
    for evalCase in LiveEval.cases {
      for check in evalCase.checks {
        guard let pattern = check.pattern else { continue }
        #expect((try? NSRegularExpression(pattern: pattern)) != nil, "\(evalCase.id): /\(pattern)/")
      }
    }
  }

  @Test(arguments: LiveEval.cases)
  func checksAcceptValidVariantsAndRejectKnownBad(_ evalCase: LiveCase) {
    #expect(!evalCase.accepts.isEmpty)
    #expect(!evalCase.rejects.isEmpty)
    for output in evalCase.accepts {
      let failures = LiveEval.evaluate(evalCase, output: output)
      #expect(failures.isEmpty, "rejected valid \"\(output)\": \(failures)")
    }
    for output in evalCase.rejects {
      #expect(!LiveEval.evaluate(evalCase, output: output).isEmpty, "accepted bad \"\(output)\"")
    }
  }

  @Test func editRatioMeasuresRewrites() {
    #expect(LiveEval.editRatio("Like Notion.", "like notion.") == 0)
    #expect(LiveEval.editRatio("abcd", "abce") == 0.25)
    #expect(LiveEval.editRatio("", "abc") == 1)
  }
}

nonisolated struct LiveCase: Sendable, CustomTestStringConvertible {
  nonisolated enum Direction: String, CaseIterable, Sendable {
    case proofreadEnglish = "en>en"
    case portugueseToEnglish = "pt>en"
    case englishToPortuguese = "en>pt-BR"

    /// The default targets' `language`; `targetsMatchDefaultSettings` keeps them in sync.
    var targetLanguage: String {
      switch self {
      case .proofreadEnglish, .portugueseToEnglish: "english"
      case .englishToPortuguese: "Brazilian Portuguese"
      }
    }

    var outputLanguage: NLLanguage {
      self == .englishToPortuguese ? .portuguese : .english
    }
  }

  let id: String
  let direction: Direction
  let source: String
  let checks: [LiveCheck]
  /// Outputs a careful reviewer would accept. All must pass, so checks never demand one wording.
  let accepts: [String]
  /// Known-bad outputs, including real regressions. Each must fail at least one check.
  let rejects: [String]

  var testDescription: String { id }
}

nonisolated enum LiveCheck: Sendable {
  /// Regex over the output folded to lowercase without accents: `nao` matches "Não".
  case matches(String, String)
  /// Regex that must not match the folded output; the second value says why.
  case avoids(String, String)
  /// Exact, case-sensitive substrings: code, URLs, paths, names, numbers.
  case keeps([String])
  case nonEmptyLines(Int)
  case endsWith(String)
  /// For already natural text: max normalized edit distance from the source.
  case closeToSource(Double)

  var pattern: String? {
    switch self {
    case .matches(let pattern, _), .avoids(let pattern, _): pattern
    default: nil
    }
  }
}

nonisolated struct LiveResult: Codable, Sendable {
  var run = LiveEval.runID
  var prompt = LiveEval.promptFingerprint
  var backend = ""
  var model = ""
  let id: String
  let direction: String
  let source: String
  var output: String?
  var passed = false
  var failures: [String] = []
  var error: String?
  var firstTokenMs: Int?
  var totalMs: Int?
  var partials = 0
  var trace: [String] = []

  var summary: String {
    let status = passed ? "PASS" : "FAIL"
    let total = totalMs.map { "\($0) ms" } ?? "-"
    let first = firstTokenMs.map { "\($0) ms" } ?? "-"
    var lines = ["[live-eval] \(status) \(id) (\(direction)) total \(total), first token \(first), \(backend) \(model)"]
    lines.append("  source: \(Self.oneLine(source))")
    if let output { lines.append("  output: \(Self.oneLine(output))") }
    if let error { lines.append("  error: \(error)") }
    lines += failures.map { "  fail: \($0)" }
    return lines.joined(separator: "\n")
  }

  private static func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: "⏎ ")
  }
}

nonisolated struct LiveEvalError: Error, CustomStringConvertible {
  let description: String
}

actor LiveStreamProbe {
  private let start = ContinuousClock.now
  private(set) var firstPartial: Duration?
  private(set) var partials = 0
  private(set) var traces: [String] = []

  func partial() {
    partials += 1
    if firstPartial == nil { firstPartial = ContinuousClock.now - start }
  }

  func trace(_ line: String) { traces.append(line) }

  func elapsed() -> Duration { ContinuousClock.now - start }
}

nonisolated enum LiveEval {
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["TRANSLATION_LIVE_TESTS"] == "1"
  }

  static let runID = Date().formatted(.iso8601)

  /// Changes with the prompt text, so before/after artifacts can't be mixed up.
  static let promptFingerprint: String = {
    let material = [
      PromptBuilder.systemPrompt,
      PromptBuilder.userPrompt(text: "{text}", targetLanguage: "english"),
      PromptBuilder.userPrompt(text: "{text}", targetLanguage: "Brazilian Portuguese"),
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(material.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }()

  /// The app's default engine and model. `TRANSLATION_LIVE_BACKEND` (local, claude, codex)
  /// and `TRANSLATION_LIVE_MODEL` override them for side-by-side runs.
  @MainActor static func makeTranslator() throws -> Translator {
    var settings = AppSettings.default
    let environment = ProcessInfo.processInfo.environment
    if let name = environment["TRANSLATION_LIVE_BACKEND"], !name.isEmpty {
      guard let engine = TranslationEngine(rawValue: name) else {
        throw LiveEvalError(description: "unknown TRANSLATION_LIVE_BACKEND=\(name); use local, claude, or codex")
      }
      settings.engine = engine
    }
    var configuration = settings.engineConfiguration
    if let model = environment["TRANSLATION_LIVE_MODEL"], !model.isEmpty {
      configuration.model = model
    }
    return Translator(configuration: configuration)
  }

  @MainActor static func run(_ evalCase: LiveCase) async -> LiveResult {
    var result = LiveResult(id: evalCase.id, direction: evalCase.direction.rawValue, source: evalCase.source)
    let translator: Translator
    do {
      translator = try makeTranslator()
    } catch {
      result.error = "\(error)"
      return result
    }
    result.backend = translator.configuration.engine.rawValue
    result.model = translator.configuration.model.isEmpty ? "(cli default)" : translator.configuration.model

    let probe = LiveStreamProbe()
    do {
      let output = try await translator.translate(
        text: evalCase.source,
        targetLanguage: evalCase.direction.targetLanguage,
        onOutput: { line in await probe.trace(line) },
        onPartial: { _ in await probe.partial() }
      )
      result.output = output
      result.failures = evaluate(evalCase, output: output)
    } catch {
      result.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
    result.totalMs = milliseconds(await probe.elapsed())
    let firstPartial = await probe.firstPartial
    result.firstTokenMs = firstPartial.map(milliseconds)
    result.partials = await probe.partials
    result.trace = await probe.traces
    result.passed = result.error == nil && result.failures.isEmpty
    return result
  }

  /// Appends one JSON line per case when `TRANSLATION_LIVE_RESULTS` names a file.
  static func record(_ result: LiveResult) throws {
    guard let path = ProcessInfo.processInfo.environment["TRANSLATION_LIVE_RESULTS"], !path.isEmpty else {
      return
    }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(result)
    line.append(0x0A)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  // MARK: Checks

  static func evaluate(_ evalCase: LiveCase, output: String) -> [String] {
    let folded = fold(output)
    var failures: [String] = []
    for check in evalCase.checks {
      switch check {
      case .matches(let pattern, let why):
        if !found(pattern, in: folded) { failures.append("missing \(why) /\(pattern)/") }
      case .avoids(let pattern, let why):
        if found(pattern, in: folded) { failures.append("\(why) /\(pattern)/") }
      case .keeps(let literals):
        for literal in literals where !output.contains(literal) {
          failures.append("changed or dropped `\(literal)`")
        }
      case .nonEmptyLines(let expected):
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        if lines.count != expected { failures.append("expected \(expected) non-empty lines, got \(lines.count)") }
      case .endsWith(let suffix):
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(suffix) {
          failures.append("should end with \(suffix)")
        }
      case .closeToSource(let limit):
        let ratio = editRatio(evalCase.source, output)
        if ratio > limit {
          failures.append(String(format: "rewrote already natural text: edit ratio %.2f > %.2f", ratio, limit))
        }
      }
    }
    return failures + generalFailures(evalCase, output: output, folded: folded)
  }

  private static let spanishOnly = #"\b(pero|ayer|usted|ustedes|hacer|ahora|tambien|manana|gracias|necesito|puedes)\b"#
  private static let label = #"^\s*(translation|traducao|corrected text|proofread text|here'?s the (translation|corrected text)|here is the (translation|corrected text))\b"#

  /// Checks every case gets, whatever its specific checks are.
  private static func generalFailures(_ evalCase: LiveCase, output: String, folded: String) -> [String] {
    var failures: [String] = []
    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("empty output") }
    if output.contains("<text>") || output.contains("</text>") { failures.append("leaked <text> delimiters") }
    if found(label, in: folded) { failures.append("added a label or preamble") }
    if evalCase.direction != .proofreadEnglish, folded == fold(evalCase.source) {
      failures.append("returned the source untranslated")
    }
    if evalCase.direction.outputLanguage == .portuguese, found(spanishOnly, in: folded) {
      failures.append("Spanish words in Brazilian Portuguese output")
    }
    if let language = confidentLanguage(of: output), language != evalCase.direction.outputLanguage {
      failures.append("reads as \(language.rawValue), expected \(evalCase.direction.outputLanguage.rawValue)")
    }
    return failures
  }

  /// Lowercase, no accents, straight apostrophes and quotes.
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .replacingOccurrences(of: "’", with: "'")
      .replacingOccurrences(of: "‘", with: "'")
      .replacingOccurrences(of: "“", with: "\"")
      .replacingOccurrences(of: "”", with: "\"")
  }

  static func found(_ pattern: String, in text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else {
      return false
    }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// Character-level Levenshtein distance over folded text, divided by the longer length.
  static func editRatio(_ source: String, _ output: String) -> Double {
    let a = Array(fold(source).lowercased())
    let b = Array(fold(output).lowercased())
    if a.isEmpty || b.isEmpty { return a.count == b.count ? 0 : 1 }
    var previous = Array(0...b.count)
    var current = previous
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return Double(previous[b.count]) / Double(max(a.count, b.count))
  }

  /// English, Portuguese, or Spanish when the recognizer is confident, ignoring code and URLs.
  /// Nil for short text, where it guesses.
  static func confidentLanguage(of text: String) -> NLLanguage? {
    let prose = text
      .replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
    let words = prose.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
    guard words.count >= 6 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [.english, .portuguese, .spanish]
    recognizer.processString(prose)
    guard
      let best = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
      best.value >= 0.7
    else { return nil }
    return best.key
  }

  static func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
  }
}
