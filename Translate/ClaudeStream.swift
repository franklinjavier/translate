import Foundation

nonisolated struct ClaudeStreamPulse: Sendable {
  var displayed: String?
  var traces: [String] = []
}

nonisolated struct ClaudeStreamParser: Sendable {
  private var buffer = ""
  private(set) var streamed = ""
  private(set) var resultText: String?
  private(set) var deltaCount = 0
  /// The CLI's final result was an error report (auth, quota…), so its text isn't a translation.
  private(set) var resultIsError = false

  var finalText: String {
    let text = resultText ?? streamed
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func consume(_ chunk: String) -> ClaudeStreamPulse {
    buffer += chunk
    var pulse = ClaudeStreamPulse()
    while let newline = buffer.firstIndex(of: "\n") {
      let line = String(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      apply(line, into: &pulse)
    }
    return pulse
  }

  mutating func finish() -> ClaudeStreamPulse {
    var pulse = ClaudeStreamPulse()
    if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      apply(buffer, into: &pulse)
    }
    buffer = ""
    return pulse
  }

  private mutating func apply(_ line: String, into pulse: inout ClaudeStreamPulse) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard
      let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      pulse.traces.append("skip non-json")
      return
    }

    switch type {
    case "stream_event":
      if let text = Self.textDelta(in: object), !text.isEmpty {
        deltaCount += 1
        streamed += text
        pulse.displayed = streamed
        pulse.traces.append("delta #\(deltaCount) +\(text.count) total=\(streamed.count)")
        return
      }
      if let inner = (object["event"] as? [String: Any])?["type"] as? String {
        note("stream_event/\(Self.knownEvents.contains(inner) ? inner : "other")", into: &pulse)
      }
    case "assistant":
      guard streamed.isEmpty, let text = Self.assistantText(in: object), !text.isEmpty else {
        note("assistant", into: &pulse)
        return
      }
      streamed = text
      pulse.displayed = streamed
      pulse.traces.append("assistant \(text.count) chars")
    case "result":
      if object["is_error"] as? Bool == true {
        resultIsError = true
        pulse.traces.append("result is_error")
      }
      guard let text = object["result"] as? String else {
        pulse.traces.append("result (no text)")
        return
      }
      resultText = text
      if streamed.isEmpty, !resultIsError {
        streamed = text
        pulse.displayed = streamed
      }
      pulse.traces.append("result \(text.count) chars")
    default:
      // Event names are the CLI's own vocabulary; anything else is noted as unknown.
      note(Self.knownTypes.contains(type) ? type : "other", into: &pulse)
    }
  }

  private var seenEvents: Set<String> = []

  private mutating func note(_ label: String, into pulse: inout ClaudeStreamPulse) {
    guard seenEvents.insert(label).inserted else { return }
    pulse.traces.append("event \(label)")
  }

  private static func textDelta(in object: [String: Any]) -> String? {
    if let event = object["event"] as? [String: Any] {
      if let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String {
        let deltaType = delta["type"] as? String
        if deltaType == nil || deltaType == "text_delta" || deltaType == "text" {
          return text
        }
      }
    }
    if let delta = object["delta"] as? [String: Any], let text = delta["text"] as? String {
      return text
    }
    return nil
  }

  private static func assistantText(in object: [String: Any]) -> String? {
    guard
      let message = object["message"] as? [String: Any],
      let content = message["content"] as? [[String: Any]]
    else { return nil }
    let parts = content.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }
    let joined = parts.joined()
    return joined.isEmpty ? nil : joined
  }

  // Traces name only the CLI's own event vocabulary, so nothing read from stdout reaches a log.
  private static let knownTypes: Set<String> = ["system", "user", "rate_limit_event"]
  private static let knownEvents: Set<String> = [
    "message_start", "content_block_start", "content_block_delta", "content_block_stop",
    "message_delta", "message_stop",
  ]
}
