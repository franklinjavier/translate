import Foundation

nonisolated enum LocalMLX {
  static let defaultEndpoint = URL(string: "http://127.0.0.1:8765/v1/chat/completions")!
  static let defaultModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

  /// Streams a translation from the local MLX server. Returns only when the
  /// server reports a complete answer; truncated, errored, or cut-off
  /// streams throw. Traces carry lifecycle metadata and counts only.
  @concurrent
  static func translate(
    text: String,
    targetLanguage: String,
    model: String,
    onPartial: @escaping @Sendable (String) async -> Void,
    trace: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? defaultModel
      : model.trimmingCharacters(in: .whitespacesAndNewlines)
    await trace("Local MLX \(modelID)")
    await trace("POST \(defaultEndpoint.absoluteString) stream=true")

    let body: [String: Any] = [
      "model": modelID,
      "temperature": 0,
      "max_tokens": maxTokens(for: text),
      "stream": true,
      "messages": [
        ["role": "system", "content": PromptBuilder.systemPrompt],
        ["role": "user", "content": PromptBuilder.userPrompt(text: text, targetLanguage: targetLanguage)],
      ],
    ]
    let payload = try JSONSerialization.data(withJSONObject: body)

    var request = URLRequest(url: defaultEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120
    request.httpBody = payload

    var parser = LocalMLXStreamParser()
    var assembled = ""
    var deltaCount = 0

    func deliver(_ pieces: [String]) async {
      for piece in pieces {
        deltaCount += 1
        assembled += piece
        if deltaCount == 1 {
          await trace("first token")
        }
        await onPartial(assembled)
      }
    }

    do {
      for try await chunk in LocalMLXByteStream.open(request) {
        try Task.checkCancellation()
        await deliver(try parser.consume(chunk))
      }
      try Task.checkCancellation()
      await deliver(try parser.finish())
    } catch {
      if case .failed(let failure) = parser.state {
        await trace("deltas=\(deltaCount) chars=\(assembled.count) failed=\(failure)")
      }
      throw error
    }

    let reason = if case .finished(let completion) = parser.state { completion.rawValue } else { "?" }
    await trace("deltas=\(deltaCount) chars=\(assembled.count) finish=\(reason)")
    return assembled
  }

  private static func maxTokens(for text: String) -> Int {
    min(2_048, max(128, text.count * 2))
  }

  fileprivate static func mappedURLError(_ error: URLError) -> Error {
    switch error.code {
    case .cancelled:
      return CancellationError()
    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
      return TranslatorError.localUnavailable(
        "Local MLX isn’t running. In Terminal: local-translate-server start"
      )
    default:
      return error
    }
  }
}

/// Pure, synchronous parser for an OpenAI-compatible chat completion
/// response: either an SSE stream (`data:` lines) or a single JSON body.
/// Feed raw bytes with `consume(_:)`, then call `finish()` at clean EOF.
/// Lines are split at the byte level, so lines and multi-byte UTF-8
/// characters may straddle chunk boundaries.
nonisolated struct LocalMLXStreamParser: Sendable {
  nonisolated enum Completion: String, Equatable, Sendable {
    /// `finish_reason: "stop"`.
    case stop
    /// `data: [DONE]` without a stop reason.
    case done = "[DONE]"
  }

  nonisolated enum Failure: Error, Equatable, Sendable {
    case truncated
    case stopped
    case serverError
    case prematureEOF
    case unreadable

    /// Fixed, user-facing text. Never includes server text, prompt, or output.
    var message: String {
      switch self {
      case .truncated:
        "Local MLX stopped before finishing the translation (token limit). Select less text and try again."
      case .stopped:
        "Local MLX stopped before finishing the translation."
      case .serverError:
        "Local MLX reported an error while translating."
      case .prematureEOF:
        "Local MLX closed the connection before finishing the translation."
      case .unreadable:
        "Local MLX sent a response this app can't read."
      }
    }

    var error: TranslatorError { .localUnavailable(message) }
  }

  nonisolated enum State: Equatable, Sendable {
    case streaming
    case finished(Completion)
    case failed(Failure)
  }

  private enum Mode {
    case undetermined
    case events
    case jsonBody
  }

  private(set) var state: State = .streaming
  private var mode: Mode = .undetermined
  private var pending: [UInt8] = []

  /// Returns the non-empty text deltas contained in the complete lines of
  /// `chunk`. Throws `TranslatorError.localUnavailable` on a server error,
  /// truncation, or unreadable data. Data after a finish is ignored.
  mutating func consume(_ chunk: Data) throws -> [String] {
    if case .failed(let failure) = state { throw failure.error }
    if case .finished = state { return [] }
    pending.append(contentsOf: chunk)
    do throws(Failure) {
      return try drainLines()
    } catch {
      try fail(error)
    }
  }

  /// Flushes a final unterminated line and validates that the response
  /// reached a successful terminal state. Returns any trailing text.
  mutating func finish() throws -> [String] {
    if case .failed(let failure) = state { throw failure.error }
    do throws(Failure) {
      var texts: [String] = []
      if case .streaming = state {
        switch mode {
        case .jsonBody:
          try apply(payload: pending[...], into: &texts)
        case .events, .undetermined:
          if !pending.isEmpty { try handle(line: pending[...], into: &texts) }
        }
      }
      pending = []
      guard case .finished = state else { throw Failure.prematureEOF }
      return texts
    } catch {
      try fail(error)
    }
  }

  private mutating func fail(_ failure: Failure) throws -> Never {
    state = .failed(failure)
    pending = []
    throw failure.error
  }

  private mutating func drainLines() throws(Failure) -> [String] {
    if mode == .undetermined {
      guard let first = pending.first(where: { !Self.isWhitespace($0) }) else { return [] }
      mode = first == UInt8(ascii: "{") ? .jsonBody : .events
    }
    // A plain JSON body (non-streaming reply) is parsed whole in `finish()`.
    guard mode == .events else { return [] }

    var texts: [String] = []
    var lineStart = pending.startIndex
    while case .streaming = state,
          let newline = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
      try handle(line: pending[lineStart..<newline], into: &texts)
      lineStart = newline + 1
    }
    if case .finished = state {
      pending = []
    } else {
      pending.removeSubrange(..<lineStart)
    }
    return texts
  }

  private static let dataField = Array("data:".utf8)

  private mutating func handle(line: ArraySlice<UInt8>, into texts: inout [String]) throws(Failure) {
    var line = line
    if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
    // Blank lines, `:` comments, and `event:`/`id:`/`retry:` fields carry no text.
    guard line.starts(with: Self.dataField) else { return }
    var payload = line.dropFirst(Self.dataField.count)
    while let first = payload.first, Self.isWhitespace(first) { payload = payload.dropFirst() }
    while let last = payload.last, Self.isWhitespace(last) { payload = payload.dropLast() }
    guard !payload.isEmpty else { return }
    if payload.elementsEqual("[DONE]".utf8) {
      state = .finished(.done)
      return
    }
    try apply(payload: payload, into: &texts)
  }

  private mutating func apply(payload: ArraySlice<UInt8>, into texts: inout [String]) throws(Failure) {
    guard
      let parsed = try? JSONSerialization.jsonObject(with: Data(payload)),
      let object = parsed as? [String: Any]
    else { throw .unreadable }

    if let error = object["error"], !(error is NSNull) { throw .serverError }
    guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return }

    let text = (choice["delta"] as? [String: Any])?["content"] as? String
      ?? (choice["message"] as? [String: Any])?["content"] as? String
    if let text, !text.isEmpty { texts.append(text) }

    switch choice["finish_reason"] {
    case nil, is NSNull:
      break
    case let reason as String where reason == "stop":
      state = .finished(.stop)
    case let reason as String where reason == "length":
      throw .truncated
    default:
      throw .stopped
    }
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
      || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
  }
}

/// Delegate-based HTTP so SSE bytes reach the parser as they arrive.
/// `URLSession.bytes` can hold the body until the connection closes.
/// This type only moves bytes and maps transport errors; it holds no
/// mutable state. Finishing an `AsyncThrowingStream` twice is a no-op,
/// and the session is invalidated whenever the stream terminates
/// (completion, failure, or consumer cancellation).
nonisolated private final class LocalMLXByteStream: NSObject, URLSessionDataDelegate, Sendable {
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation

  private init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
    self.continuation = continuation
  }

  static func open(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let config = URLSessionConfiguration.ephemeral
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      config.urlCache = nil
      config.timeoutIntervalForRequest = 120
      config.timeoutIntervalForResource = 120
      config.httpMaximumConnectionsPerHost = 4
      let delegate = LocalMLXByteStream(continuation: continuation)
      // The session retains its delegate until invalidated.
      let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
      continuation.onTermination = { _ in
        session.invalidateAndCancel()
      }
      session.dataTask(with: request).resume()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      continuation.finish(throwing: TranslatorError.localUnavailable("Local MLX returned an invalid response."))
      return
    }
    guard (200..<300).contains(http.statusCode) else {
      completionHandler(.cancel)
      continuation.finish(
        throwing: TranslatorError.localUnavailable(
          "Local MLX failed (HTTP \(http.statusCode)). Is local-translate-server running?"
        )
      )
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    switch error {
    case nil:
      continuation.finish()
    case let urlError as URLError:
      continuation.finish(throwing: LocalMLX.mappedURLError(urlError))
    case let error?:
      continuation.finish(throwing: error)
    }
  }
}
