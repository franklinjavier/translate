import SwiftUI

struct StreamingText: View {
  var text: String
  var isStreaming: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var revealed = ""
  @State private var incoming = ""
  @State private var incomingOpacity = 1.0
  @State private var caretOn = true

  var body: some View {
    (Text(revealed) + incomingRun + caretRun)
      .font(.system(size: 16))
      .lineSpacing(4)
      .foregroundStyle(.primary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: text, initial: true) { _, newValue in
        consume(newValue)
      }
      .onChange(of: isStreaming) { _, streaming in
        if !streaming {
          revealed = text
          incoming = ""
          incomingOpacity = 1
          caretOn = false
        }
      }
      .task(id: isStreaming) {
        guard isStreaming else {
          caretOn = false
          return
        }
        caretOn = true
        guard !reduceMotion else { return }
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(530))
          caretOn.toggle()
        }
      }
  }

  private var incomingRun: Text {
    Text(incoming)
      .foregroundStyle(.primary.opacity(incomingOpacity))
  }

  private var caretRun: Text {
    guard isStreaming else { return Text("") }
    return Text("▍")
      .foregroundStyle(.primary.opacity(caretOn ? 0.82 : 0.12))
  }

  private func consume(_ newValue: String) {
    if newValue.hasPrefix(revealed) {
      let nextIncoming = String(newValue.dropFirst(revealed.count))
      let startedChunk = incoming.isEmpty && !nextIncoming.isEmpty
      incoming = nextIncoming
      guard startedChunk, !reduceMotion else { return }
      incomingOpacity = 0.42
      withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) {
        incomingOpacity = 1
      } completion: {
        revealed = revealed + incoming
        incoming = ""
      }
    } else {
      revealed = newValue
      incoming = ""
      incomingOpacity = 1
    }
  }
}
