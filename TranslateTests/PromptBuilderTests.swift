import Foundation
import Testing
@testable import Translate

struct PromptBuilderTests {
  @Test func userPromptIncludesLanguageAndSource() {
    let prompt = PromptBuilder.userPrompt(text: "oi, tudo bem?", targetLanguage: "english")
    #expect(prompt.contains("english"))
    #expect(prompt.contains("oi, tudo bem?"))
    #expect(prompt.contains("casual tone"))
  }

  @Test func systemPromptForbidsQuotesAndPreamble() {
    #expect(PromptBuilder.systemPrompt.contains("Output only the translation"))
    #expect(PromptBuilder.systemPrompt.contains("quotes"))
    #expect(PromptBuilder.systemPrompt.contains("never Spanish"))
  }

  @Test func systemPromptKeepsTechnicalTermsInEnglish() {
    #expect(PromptBuilder.systemPrompt.contains("Keep technical terms in English"))
    #expect(PromptBuilder.systemPrompt.contains("branch base"))
    #expect(PromptBuilder.systemPrompt.contains("pull request"))
  }
}

struct AppSettingsDecodingTests {
  @Test func oldJSONKeepsTargetsWithoutAppleFlag() throws {
    let json = """
      {
        "backend": "claude",
        "claudePath": "",
        "claudeModel": "sonnet",
        "codexPath": "",
        "codexModel": "",
        "targets": [
          {"id": "00000000-0000-0000-0000-000000000001", "label": "English", "language": "english"},
          {"id": "00000000-0000-0000-0000-000000000002", "label": "Portuguese", "language": "Brazilian Portuguese"}
        ],
        "launchAtLogin": false
      }
      """
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.useAppleOnDeviceModel == false)
    #expect(settings.claudeModel == "sonnet")
    #expect(settings.targets.count == 2)
  }

  @Test func decodesLocalBackend() throws {
    let json = """
      {"backend":"local","targets":[],"launchAtLogin":false}
      """
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.backend == .local)
  }
}

struct AppleLanguageMapperTests {
  @Test func mapsEnglishAndBrazilianPortuguese() {
    #expect(AppleLanguageMapper.language(from: "english")?.languageCode?.identifier == "en")
    #expect(AppleLanguageMapper.language(from: "Brazilian Portuguese")?.languageCode?.identifier == "pt")
    #expect(AppleLanguageMapper.language(from: "Portuguese")?.languageCode?.identifier == "pt")
  }

  @Test func detectsEnglishSource() {
    let language = AppleLanguageMapper.detectedLanguage(
      in: "The protocol here is good, and several of its rules are earned lessons."
    )
    #expect(language.map(AppleLanguageMapper.code)?.hasPrefix("en") == true)
  }

  @Test func splitsLongTextIntoSentences() {
    let text = "First sentence here. Second sentence follows. Third one wraps it up."
    let units = TranslationUnits.split(text)
    #expect(units.count >= 2)
    #expect(units.joined() == text || units.joined().contains("First sentence"))
  }

  @Test func keepsShortTextWhole() {
    #expect(TranslationUnits.split("Hello.") == ["Hello."])
  }
}

struct ClaudeStreamParserTests {
  @Test func accumulatesTextDeltasAcrossChunks() {
    var parser = ClaudeStreamParser()
    let first = parser.consume(
      """
      {"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Olá"}}}

      """
    )
    #expect(first.displayed == "Olá")
    let second = parser.consume(
      """
      {"type":"stream_event","event":{"delta":{"type":"text_delta","text":" mundo"}}}
      {"type":"result","result":"Olá mundo"}

      """
    )
    #expect(second.displayed == "Olá mundo")
    #expect(parser.finalText == "Olá mundo")
    #expect(parser.deltaCount == 2)
  }

  @Test func buffersIncompleteJSONLine() {
    var parser = ClaudeStreamParser()
    let incomplete = parser.consume(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Lan"#)
    #expect(incomplete.displayed == nil)
    let rest = parser.consume("çante\"}}}\n")
    #expect(rest.displayed == "Lançante")
  }

  @Test func usesAssistantWhenNoDeltas() {
    var parser = ClaudeStreamParser()
    let pulse = parser.consume(
      """
      {"type":"assistant","message":{"content":[{"type":"text","text":"pronto"}]}}

      """
    )
    #expect(pulse.displayed == "pronto")
    #expect(parser.finalText == "pronto")
  }

  @Test func prefersResultAsFinalText() {
    var parser = ClaudeStreamParser()
    _ = parser.consume(
      """
      {"type":"stream_event","event":{"delta":{"type":"text_delta","text":"parcial"}}}
      {"type":"result","result":"completo"}

      """
    )
    #expect(parser.finalText == "completo")
  }

  @Test func tracesInitOnce() {
    var parser = ClaudeStreamParser()
    let first = parser.consume(
      """
      {"type":"system","subtype":"init"}
      {"type":"system","subtype":"init"}

      """
    )
    #expect(first.traces == ["event system/init"])
  }
}

struct LocalMLXStreamTests {
  @Test func readsStreamingDelta() {
    let line = #"data: {"choices":[{"delta":{"content":"Este"}}]}"#
    #expect(LocalMLXStream.deltaText(in: line) == "Este")
  }

  @Test func ignoresDone() {
    #expect(LocalMLXStream.deltaText(in: "data: [DONE]") == nil)
  }

  @Test func ignoresEmptyDelta() {
    let line = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
    #expect(LocalMLXStream.deltaText(in: line) == nil)
  }
}

struct OutputSanitizerTests {
  @Test func trimsWhitespace() {
    #expect(OutputSanitizer.sanitize("  hello  \n") == "hello")
  }

  @Test func stripsWrappingDoubleQuotes() {
    #expect(OutputSanitizer.sanitize("\"hello there\"") == "hello there")
  }

  @Test func stripsWrappingSmartQuotes() {
    #expect(OutputSanitizer.sanitize("“hello”") == "hello")
  }

  @Test func leavesInternalQuotesAlone() {
    #expect(OutputSanitizer.sanitize("He said \"hi\"") == "He said \"hi\"")
  }

  @Test func emptyStaysEmpty() {
    #expect(OutputSanitizer.sanitize("   ") == "")
  }
}

struct OverlayHotkeysTests {
  @Test func enterReplacesWithoutCommand() {
    #expect(
      OverlayHotkeys.action(keyCode: 36, command: false, option: false, control: false, shift: false)
        == .replace
    )
  }

  @Test func commandCCopies() {
    #expect(
      OverlayHotkeys.action(keyCode: 8, command: true, option: false, control: false, shift: false)
        == .copy
    )
  }

  @Test func escapeCloses() {
    #expect(
      OverlayHotkeys.action(keyCode: 53, command: false, option: false, control: false, shift: false)
        == .close
    )
  }

  @Test func shiftEnterIsIgnored() {
    #expect(
      OverlayHotkeys.action(keyCode: 36, command: false, option: false, control: false, shift: true)
        == nil
    )
  }
}

struct SelectedTextSplicerTests {
  @Test func replacesSelectedSpan() {
    #expect(
      SelectedTextSplicer.splice(
        value: "hello world",
        utf16Location: 6,
        utf16Length: 5,
        insertion: "there"
      ) == "hello there"
    )
  }

  @Test func rejectsOutOfRange() {
    #expect(
      SelectedTextSplicer.splice(
        value: "hi",
        utf16Location: 0,
        utf16Length: 8,
        insertion: "x"
      ) == nil
    )
  }

  @Test func replacesFirstOccurrence() {
    #expect(
      SelectedTextSplicer.replacingFirstOccurrence(
        of: "hello world",
        in: "hello world",
        with: "olá mundo"
      ) == "olá mundo"
    )
  }
}
