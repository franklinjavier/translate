import Foundation
import Testing
@testable import Translate

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
    #expect(first.traces == ["event system"])
  }

  @Test func tracesCarryCountsNeverText() {
    var parser = ClaudeStreamParser()
    let secret = "segredo"
    let pulse = parser.consume(
      """
      {"type":"stream_event","event":{"delta":{"type":"text_delta","text":"\(secret)"}}}
      {"type":"\(secret)"}
      {"type":"stream_event","event":{"type":"\(secret)"}}
      not json \(secret)
      {"type":"result","result":"\(secret)","error":"\(secret)"}

      """
    )
    #expect(pulse.displayed == secret)
    #expect(!pulse.traces.isEmpty)
    #expect(pulse.traces.allSatisfy { !$0.contains(secret) })
  }

  @Test func errorResultIsFlaggedAndNotDisplayed() {
    var parser = ClaudeStreamParser()
    let pulse = parser.consume(
      """
      {"type":"result","is_error":true,"result":"Invalid API key"}

      """
    )
    #expect(parser.resultIsError)
    #expect(pulse.displayed == nil)
  }
}
