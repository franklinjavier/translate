import Foundation

nonisolated enum LocalMLX {
  static let defaultEndpoint = URL(string: "http://127.0.0.1:8765/v1/chat/completions")!
  static let defaultModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

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

    let pieces = AsyncThrowingStream<String, Error> { continuation in
      let client = LocalMLXHTTPClient(continuation: continuation)
      continuation.onTermination = { _ in
        client.cancel()
      }
      client.start(request)
    }

    var assembled = ""
    var deltaCount = 0
    do {
      for try await piece in pieces {
        if Task.isCancelled { throw CancellationError() }
        deltaCount += 1
        assembled += piece
        if deltaCount == 1 {
          await trace("first token")
        }
        await onPartial(assembled)
      }
    } catch let error as URLError {
      throw mappedURLError(error)
    }
    await trace("deltas=\(deltaCount) chars=\(assembled.count)")
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

nonisolated enum LocalMLXStream {
  static func deltaText(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("data:") else { return nil }
    let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard payload != "[DONE]", !payload.isEmpty else { return nil }
    guard
      let data = payload.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = object["choices"] as? [[String: Any]],
      let first = choices.first
    else { return nil }
    if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String {
      return text
    }
    if let message = first["message"] as? [String: Any], let text = message["content"] as? String {
      return text
    }
    return nil
  }
}

/// Delegate-based HTTP so SSE tokens reach the overlay as they arrive.
/// `URLSession.bytes` can hold the body until the connection closes.
nonisolated private final class LocalMLXHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let continuation: AsyncThrowingStream<String, Error>.Continuation
  private var buffer = Data()
  private var session: URLSession?
  private var finished = false
  private let lock = NSLock()

  init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
    self.continuation = continuation
  }

  func start(_ request: URLRequest) {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 120
    config.httpMaximumConnectionsPerHost = 4
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    self.session = session
    session.dataTask(with: request).resume()
  }

  func cancel() {
    session?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      fail(TranslatorError.localUnavailable("Local MLX returned an invalid response."))
      return
    }
    guard (200..<300).contains(http.statusCode) else {
      completionHandler(.cancel)
      fail(
        TranslatorError.localUnavailable(
          "Local MLX failed (HTTP \(http.statusCode)). Is local-translate-server running?"
        )
      )
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    buffer.append(data)
    let lines = drainLinesLocked()
    lock.unlock()
    for line in lines {
      continuation.yield(line)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let trailing = drainLinesLocked()
    var leftover: String?
    if !buffer.isEmpty {
      leftover = String(data: buffer, encoding: .utf8)
      buffer.removeAll()
    }
    lock.unlock()

    for line in trailing {
      continuation.yield(line)
    }
    if let leftover, let piece = LocalMLXStream.deltaText(in: leftover), !piece.isEmpty {
      continuation.yield(piece)
    }

    if let error {
      if let urlError = error as? URLError {
        fail(LocalMLX.mappedURLError(urlError))
      } else {
        fail(error)
      }
      session.finishTasksAndInvalidate()
      return
    }
    finish()
    session.finishTasksAndInvalidate()
  }

  private func drainLinesLocked() -> [String] {
    let newline = Data("\n".utf8)
    var pieces: [String] = []
    while let range = buffer.range(of: newline) {
      let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      buffer.removeSubrange(..<range.upperBound)
      guard
        let line = String(data: lineData, encoding: .utf8),
        let piece = LocalMLXStream.deltaText(in: line),
        !piece.isEmpty
      else { continue }
      pieces.append(piece)
    }
    return pieces
  }

  private func fail(_ error: Error) {
    lock.lock()
    let already = finished
    finished = true
    lock.unlock()
    guard !already else { return }
    continuation.finish(throwing: error)
  }

  private func finish() {
    lock.lock()
    let already = finished
    finished = true
    lock.unlock()
    guard !already else { return }
    continuation.finish()
  }
}
