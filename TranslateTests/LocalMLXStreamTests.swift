import Foundation
import Testing
@testable import Translate

nonisolated struct LocalMLXStreamTests {
  typealias Failure = LocalMLXStreamParser.Failure

  // MARK: Fixtures

  static func delta(_ text: String) -> String {
    #"data: {"choices":[{"delta":{"content":"\#(text)"},"finish_reason":null}]}"# + "\n\n"
  }

  static func finish(_ reason: String) -> String {
    #"data: {"choices":[{"delta":{},"finish_reason":"\#(reason)"}]}"# + "\n\n"
  }

  static let stop = finish("stop")
  static let done = "data: [DONE]\n\n"
  static let errorObject = #"data: {"error":{"message":"secret server detail"}}"# + "\n\n"
  static let errorString = #"data: {"error":"secret server detail"}"# + "\n\n"

  nonisolated struct FailureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let body: String
    let expected: Failure
    var testDescription: String { name }
  }

  static let failureCases: [FailureCase] = [
    FailureCase(name: "length after deltas", body: delta("Hola") + finish("length") + done, expected: .truncated),
    FailureCase(name: "other finish reason", body: delta("Hola") + finish("content_filter"), expected: .stopped),
    FailureCase(name: "error object after deltas", body: delta("Hola") + errorObject + done, expected: .serverError),
    FailureCase(name: "error string after deltas", body: delta("Hola") + errorString, expected: .serverError),
    FailureCase(name: "error JSON body", body: #"{"error":{"message":"secret server detail"}}"#, expected: .serverError),
    FailureCase(name: "premature EOF", body: delta("Hola") + delta(" mundo"), expected: .prematureEOF),
    FailureCase(name: "empty response", body: "", expected: .prematureEOF),
    FailureCase(name: "malformed JSON", body: delta("Hola") + "data: {\"choices\":[{\"delta\":\n\n" + stop, expected: .unreadable),
    FailureCase(name: "JSON not an object", body: "data: [1, 2]\n\n" + stop, expected: .unreadable),
  ]

  /// Feeds `chunks` in order, then finishes. Returns the assembled text.
  static func parse(_ chunks: [Data]) throws -> String {
    var parser = LocalMLXStreamParser()
    var text = ""
    for chunk in chunks {
      text += try parser.consume(chunk).joined()
    }
    text += try parser.finish().joined()
    return text
  }

  static func parse(_ body: String) throws -> String {
    try parse([Data(body.utf8)])
  }

  // MARK: Single lines

  @Test(arguments: [
    (#"data: {"choices":[{"delta":{"content":"Este"}}]}"#, ["Este"]),
    ("data: [DONE]", []),
    (#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, []),
  ] as [(String, [String])])
  func textInSingleLine(line: String, expected: [String]) throws {
    var parser = LocalMLXStreamParser()
    #expect(try parser.consume(Data((line + "\n").utf8)) == expected)
  }

  // MARK: Completion

  @Test func completeStreamWithStopAndDone() throws {
    let body = Self.delta("Hola") + Self.delta(", mundo") + Self.stop + Self.done
    #expect(try Self.parse(body) == "Hola, mundo")
  }

  @Test func completeStreamWithStopOnly() throws {
    var parser = LocalMLXStreamParser()
    #expect(try parser.consume(Data((Self.delta("Hola") + Self.stop).utf8)) == ["Hola"])
    #expect(try parser.finish().isEmpty)
    #expect(parser.state == .finished(.stop))
  }

  @Test func completeStreamWithDoneOnly() throws {
    var parser = LocalMLXStreamParser()
    #expect(try parser.consume(Data((Self.delta("Hola") + Self.done).utf8)) == ["Hola"])
    #expect(try parser.finish().isEmpty)
    #expect(parser.state == .finished(.done))
  }

  @Test func ignoresDataAfterTerminal() throws {
    let body = Self.delta("Hola") + Self.done + Self.delta(" extra") + Self.errorObject
    #expect(try Self.parse(body) == "Hola")
  }

  @Test func nonStreamingMessageBody() throws {
    let body = """
      {
        "id": "chatcmpl-1",
        "choices": [
          {"index": 0, "message": {"role": "assistant", "content": "Olá, mundo"}, "finish_reason": "stop"}
        ]
      }
      """
    #expect(try Self.parse(body) == "Olá, mundo")
  }

  @Test func nonStreamingMessageLine() throws {
    let line = #"data: {"choices":[{"message":{"content":"Olá"},"finish_reason":"stop"}]}"#
    #expect(try Self.parse(line) == "Olá")
  }

  @Test func flushesFinalUnterminatedLine() throws {
    let last = #"data: {"choices":[{"delta":{"content":"!"},"finish_reason":"stop"}]}"#
    #expect(try Self.parse(Self.delta("Hola") + last) == "Hola!")
  }

  // MARK: Failures

  @Test(arguments: failureCases)
  func failure(_ testCase: FailureCase) {
    let error = #expect(throws: TranslatorError.self) { try Self.parse(testCase.body) }
    let message = error?.errorDescription ?? ""
    #expect(message == testCase.expected.message)
    #expect(!message.contains("secret"))
    #expect(!message.contains("Hola"))
  }

  @Test func failureIsSticky() throws {
    var parser = LocalMLXStreamParser()
    #expect(throws: TranslatorError.self) { try parser.consume(Data(Self.errorString.utf8)) }
    #expect(parser.state == .failed(.serverError))
    #expect(throws: TranslatorError.self) { try parser.consume(Data(Self.delta("Hola").utf8)) }
    #expect(throws: TranslatorError.self) { try parser.finish() }
  }

  // MARK: Framing

  @Test func chunkBoundariesAnywhereKeepExactText() throws {
    let expected = "Tradução 👋🏽 café"
    let body = Data((Self.delta("Tradução ") + Self.delta("👋🏽 café") + Self.stop + Self.done).utf8)
    // Every two-way split, including mid-line and mid multi-byte character.
    for offset in 1..<body.count {
      let chunks = [Data(body.prefix(offset)), Data(body.dropFirst(offset))]
      #expect(try Self.parse(chunks) == expected, "split at byte \(offset)")
    }
    // One byte at a time.
    #expect(try Self.parse(body.map { Data([$0]) }) == expected)
  }

  @Test func ignoresCRLFCommentsAndOtherFields() throws {
    let lines: [String] = [
      ": keep-alive",
      "event: message",
      "id: 1",
      "retry: 1000",
      #"data: {"choices":[{"delta":{"content":"Hola"}}]}"#,
      "",
      ":",
      #"data:{"choices":[{"delta":{"content":" mundo"}}]}"#,
      "",
      #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
      "",
      "data: [DONE]",
      "",
    ]
    #expect(try Self.parse(lines.joined(separator: "\r\n")) == "Hola mundo")
  }
}
