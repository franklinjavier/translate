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
        pulse.traces.append(
          "delta #\(deltaCount) +\(text.count) total=\(streamed.count) \(Self.preview(text))"
        )
        return
      }
      if let inner = (object["event"] as? [String: Any])?["type"] as? String {
        note("stream_event/\(inner)", into: &pulse)
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
      if let error = object["error"] as? String, !error.isEmpty {
        pulse.traces.append("result error \(error)")
      }
      guard let text = object["result"] as? String else {
        pulse.traces.append("result (no text)")
        return
      }
      resultText = text
      if streamed.isEmpty {
        streamed = text
        pulse.displayed = streamed
      }
      pulse.traces.append("result \(text.count) chars")
    default:
      let subtype = object["subtype"] as? String
      note(subtype.map { "\(type)/\($0)" } ?? type, into: &pulse)
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

  private static func preview(_ text: String, limit: Int = 40) -> String {
    let collapsed = text
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\t", with: "\\t")
    if collapsed.count <= limit {
      return "“\(collapsed)”"
    }
    return "“\(collapsed.prefix(limit))…”"
  }
}
