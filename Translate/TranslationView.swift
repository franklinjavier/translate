import SwiftUI

struct TranslationView: View {
  @Bindable var state: OverlayState
  var onCopy: () -> Void
  var onReplace: () -> Void
  var onOpenAccessibility: () -> Void
  var onRetry: () -> Void

  var body: some View {
    Group {
      switch state.phase {
      case .hidden:
        EmptyView()
      case .loading(let target, let source):
        panel(title: target.label, source: source) {
          loadingBody
        } trailing: {
          EmptyView()
        }
      case .streaming(let target, let source, let translation),
           .result(let target, let source, let translation):
        panel(title: target.label, source: source) {
          StreamingText(
            text: translation,
            isStreaming: {
              if case .streaming = state.phase { return true }
              return false
            }()
          )
        } trailing: {
          actionButtons
        }
      case .error(let message, let recovery):
        panel(title: "Translate", source: "") {
          Text(message)
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
          if recovery == .openAccessibility {
            HStack {
              Button("Open Accessibility Settings") {
                onOpenAccessibility()
              }
              Button("Try again") {
                onRetry()
              }
            }
            .padding(.top, 4)
          }
        } trailing: {
          EmptyView()
        }
      }
    }
    .frame(width: OverlayMetrics.width)
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      shortcutButton(title: state.copiedRecently ? "Copied" : "Copy", keys: "⌘C") {
        onCopy()
      }
      .accessibilityLabel("Copy")
      shortcutButton(title: state.replacedRecently ? "Replaced" : "Replace", keys: "↩") {
        onReplace()
      }
      .accessibilityLabel("Replace")
    }
  }

  private func shortcutButton(title: String, keys: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
        Text(keys)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var loadingBody: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("Translating…")
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(minHeight: 36)
  }

  private var scrollToken: String {
    state.currentTranslation() ?? ""
  }

  private var isStreaming: Bool {
    if case .streaming = state.phase { return true }
    return false
  }

  @ViewBuilder
  private func panel<Content: View, Trailing: View>(
    title: String,
    source: String,
    @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .tracking(0.4)
        Spacer(minLength: 8)
        trailing()
          .controlSize(.small)
      }

      let body = content()
      ScrollViewReader { proxy in
        ScrollView {
          body
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("translation-body")
        }
        .frame(maxHeight: OverlayMetrics.bodyMaxHeight)
        .onChange(of: scrollToken) { _, _ in
          guard isStreaming else { return }
          proxy.scrollTo("translation-body", anchor: .bottom)
        }
      }

      if !source.isEmpty {
        Text(source)
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
    }
  }
}
