import AppKit
import SwiftUI

struct TranslationView: View {
  @Bindable var state: OverlayState
  var presentation: PopoverPresentation
  var onCopy: () -> Void
  var onReplace: () -> Void
  var onOpenAccessibility: () -> Void
  var onRetry: () -> Void

  var body: some View {
    Group {
      switch state.phase {
      case .hidden:
        EmptyView()
      case .loading(let target, _):
        popover {
          loadingBody
          footer(label: target.label, actionsEnabled: false, replaceEnabled: false)
        }
      case .streaming(let target, _, let translation),
           .result(let target, _, let translation):
        popover {
          scrollable {
            StreamingText(text: translation, isStreaming: isStreaming)
          }
          footer(label: target.label, actionsEnabled: true, replaceEnabled: state.canReplace)
        }
      case .error(let message, let recovery):
        popover {
          scrollable {
            Text(message)
              .font(.system(size: PopoverMetrics.bodySize))
              .lineSpacing(PopoverMetrics.bodyLineSpacing)
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
          if recovery == .openAccessibility {
            HStack {
              Button("Open Accessibility Settings") {
                onOpenAccessibility()
              }
              Button("Try again") {
                onRetry()
              }
            }
            .controlSize(.small)
          }
        }
      }
    }
    // Black card regardless of system appearance, so semantic styles resolve to light text.
    .environment(\.colorScheme, .dark)
  }

  private func footer(label: String, actionsEnabled: Bool, replaceEnabled: Bool) -> some View {
    PopoverFooter(
      label: label,
      copied: state.copiedRecently,
      replaced: state.replacedRecently,
      actionsEnabled: actionsEnabled,
      replaceEnabled: replaceEnabled,
      onCopy: onCopy,
      onReplace: onReplace
    )
  }

  private var loadingBody: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(PopoverContent.loadingText)
        .font(.system(size: PopoverMetrics.bodySize))
        .foregroundStyle(.secondary)
    }
  }

  private var scrollToken: String {
    state.currentTranslation() ?? ""
  }

  private var isStreaming: Bool {
    if case .streaming = state.phase { return true }
    return false
  }

  /// Long text scrolls inside a fixed height. Short text skips the ScrollView entirely,
  /// so the hosting view's fitting height is the text's own height.
  @ViewBuilder
  private func scrollable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if presentation.scrolls {
      let body = content()
      ScrollViewReader { proxy in
        ScrollView {
          body
            .id("translation-body")
        }
        .frame(height: PopoverMetrics.bodyMaxHeight)
        .onChange(of: scrollToken) { _, _ in
          guard isStreaming else { return }
          proxy.scrollTo("translation-body", anchor: .bottom)
        }
      }
    } else {
      content()
    }
  }

  private func popover<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    let shape = PopoverShape(edge: presentation.arrowEdge, arrowX: presentation.arrowX)
    return VStack(alignment: .leading, spacing: PopoverMetrics.footerSpacing) {
      content()
    }
    .padding(.horizontal, PopoverMetrics.horizontalPadding)
    .padding(.vertical, PopoverMetrics.verticalPadding)
    .frame(width: presentation.width, alignment: .leading)
    .padding(presentation.arrowEdge == .top ? .top : .bottom, PopoverMetrics.arrowHeight)
    .background(shape.fill(Color.black))
    .overlay {
      PopoverShape(edge: presentation.arrowEdge, arrowX: presentation.arrowX, inset: 0.5)
        .stroke(.white.opacity(0.14), lineWidth: 1)
    }
  }
}

/// Target language on the left, Copy and Replace on the right, all in quiet secondary text.
struct PopoverFooter: View {
  var label: String
  var copied: Bool
  var replaced: Bool
  var actionsEnabled: Bool
  /// Off while the translation is still streaming.
  var replaceEnabled = true
  var onCopy: () -> Void
  var onReplace: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Text(label.uppercased())
        .font(.system(size: PopoverMetrics.labelSize, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: PopoverMetrics.labelActionSpacing)
      HStack(spacing: PopoverMetrics.actionSpacing) {
        action(
          titles: PopoverContent.copyTitles,
          active: copied,
          keys: PopoverContent.copyKeys,
          perform: onCopy
        )
        .accessibilityLabel("Copy")
        action(
          titles: PopoverContent.replaceTitles,
          active: replaced,
          keys: PopoverContent.replaceKeys,
          perform: onReplace
        )
        .disabled(!replaceEnabled)
        .opacity(replaceEnabled || !actionsEnabled ? 1 : 0.45)
        .accessibilityLabel("Replace")
      }
      .fixedSize()
      .disabled(!actionsEnabled)
      .opacity(actionsEnabled ? 1 : 0.45)
    }
  }

  /// `titles` holds the idle and confirmed title; both are laid out so the width never shifts.
  private func action(titles: [String], active: Bool, keys: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      HStack(spacing: PopoverMetrics.actionKeySpacing) {
        ZStack(alignment: .leading) {
          ForEach(titles, id: \.self) { title in
            Text(title)
              .opacity(title == (active ? titles[1] : titles[0]) ? 1 : 0)
          }
        }
        .font(.system(size: PopoverMetrics.actionSize, weight: .medium))
        .foregroundStyle(.white.opacity(PopoverMetrics.actionOpacity))
        Text(keys)
          .font(.system(size: PopoverMetrics.keySize))
          .foregroundStyle(.white.opacity(PopoverMetrics.keyOpacity))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

extension OverlayState.Phase {
  /// The strings that decide the popover's size for this phase.
  var popoverContent: PopoverContent {
    switch self {
    case .hidden:
      PopoverContent(text: "", label: nil, hasActions: false)
    case .loading(let target, _):
      // Reserve the action width so the card doesn't widen when the first words arrive.
      PopoverContent(text: PopoverContent.loadingText, label: target.label, hasActions: true)
    case .streaming(let target, _, let translation), .result(let target, _, let translation):
      PopoverContent(text: translation, label: target.label, hasActions: true)
    case .error(let message, let recovery):
      PopoverContent(text: message, label: nil, hasActions: false, hasRecovery: recovery == .openAccessibility)
    }
  }
}

/// Shared by the SwiftUI popover and the text measurement that sizes it, so both agree on fonts.
nonisolated enum PopoverMetrics {
  static let minWidth: CGFloat = 220
  static let maxWidth: CGFloat = 480
  static let horizontalPadding: CGFloat = 14
  static let verticalPadding: CGFloat = 12
  static let footerSpacing: CGFloat = 10
  static let cornerRadius: CGFloat = 12
  static let arrowWidth: CGFloat = 16
  static let arrowHeight: CGFloat = 7
  /// Taller translations scroll inside this height instead of growing the popover.
  static let bodyMaxHeight: CGFloat = 260

  static let bodySize: CGFloat = 15
  static let bodyLineSpacing: CGFloat = 3
  static let labelSize: CGFloat = 11
  static let actionSize: CGFloat = 12
  static let keySize: CGFloat = 11
  static let actionKeySpacing: CGFloat = 4
  static let actionSpacing: CGFloat = 12
  static let labelActionSpacing: CGFloat = 16
  /// Fixed white levels on the black card; `.tertiary` keys were too dim to read.
  static let actionOpacity: Double = 0.8
  static let keyOpacity: Double = 0.7

  static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
  static var labelFont: NSFont { .systemFont(ofSize: labelSize, weight: .semibold) }
  static var actionFont: NSFont { .systemFont(ofSize: actionSize, weight: .medium) }
  static var keyFont: NSFont { .systemFont(ofSize: keySize) }

  /// Span the arrow center can slide along without cutting into a rounded corner, from the left edge.
  static func arrowRange(width: CGFloat) -> ClosedRange<CGFloat> {
    let inset = cornerRadius + arrowWidth / 2
    return inset...max(inset, width - inset)
  }
}

/// What the popover shows for a phase, reduced to the strings that decide its size.
nonisolated struct PopoverContent: Equatable, Sendable {
  var text: String
  var label: String?
  var hasActions: Bool
  var hasRecovery: Bool = false

  static let copyTitles = ["Copy", "Copied"]
  static let replaceTitles = ["Replace", "Replaced"]
  static let copyKeys = "⌘C"
  static let replaceKeys = "↩"
  static let loadingText = "Translating…"
}

nonisolated enum PopoverSizing {
  /// Card width: the text's natural single-line width, bounded to 220–480,
  /// and never narrower than the footer needs for its label and actions.
  static func cardWidth(for content: PopoverContent) -> CGFloat {
    if content.hasRecovery { return PopoverMetrics.maxWidth }
    // Room for the streaming caret plus rounding, so the finished text doesn't rewrap.
    let caretSlack = width(of: "▍", font: PopoverMetrics.bodyFont) + 2
    let longestLine = content.text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { width(of: String($0), font: PopoverMetrics.bodyFont) }
      .max() ?? 0
    let natural = ceil(longestLine + caretSlack) + PopoverMetrics.horizontalPadding * 2
    let lower = max(PopoverMetrics.minWidth, footerWidth(for: content))
    return min(max(natural, lower), PopoverMetrics.maxWidth)
  }

  static func footerWidth(for content: PopoverContent) -> CGFloat {
    var total: CGFloat = 0
    if let label = content.label {
      total += width(of: label.uppercased(), font: PopoverMetrics.labelFont)
    }
    if content.hasActions {
      total += PopoverMetrics.labelActionSpacing
        + actionWidth(titles: PopoverContent.copyTitles, keys: PopoverContent.copyKeys)
        + PopoverMetrics.actionSpacing
        + actionWidth(titles: PopoverContent.replaceTitles, keys: PopoverContent.replaceKeys)
    }
    return ceil(total) + PopoverMetrics.horizontalPadding * 2
  }

  /// Whether the body text at `cardWidth` is taller than the popover allows.
  static func bodyScrolls(_ text: String, cardWidth: CGFloat) -> Bool {
    bodyHeight(text, cardWidth: cardWidth) > PopoverMetrics.bodyMaxHeight
  }

  static func bodyHeight(_ text: String, cardWidth: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = PopoverMetrics.bodyLineSpacing
    let measured = (text + "▍") as NSString
    let bounds = measured.boundingRect(
      with: CGSize(width: cardWidth - PopoverMetrics.horizontalPadding * 2, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: PopoverMetrics.bodyFont, .paragraphStyle: style]
    )
    return ceil(bounds.height)
  }

  private static func actionWidth(titles: [String], keys: String) -> CGFloat {
    let title = titles.map { width(of: $0, font: PopoverMetrics.actionFont) }.max() ?? 0
    return ceil(title) + PopoverMetrics.actionKeySpacing + ceil(width(of: keys, font: PopoverMetrics.keyFont))
  }

  private static func width(of string: String, font: NSFont) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: font]).width
  }
}

/// Layout the panel resolves and the view draws: card width, scrolling, and arrow attachment.
@Observable
final class PopoverPresentation {
  var width: CGFloat = PopoverMetrics.minWidth
  var scrolls = false
  /// Side of the card the arrow sits on. Space stays reserved there while the arrow is hidden.
  var arrowEdge: PopoverArrowEdge = .bottom
  /// Arrow center from the card's left edge; nil hides it.
  var arrowX: CGFloat?
}

nonisolated enum PopoverArrowEdge: Equatable, Sendable {
  /// Card above the selection, arrow pointing down.
  case bottom
  /// Card below the selection, arrow pointing up.
  case top
}

/// Rounded card with an optional arrow, drawn as one path so fill and border have no seam.
nonisolated struct PopoverShape: Shape {
  var edge: PopoverArrowEdge
  var arrowX: CGFloat?
  var inset: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    var card = rect
    card.size.height -= PopoverMetrics.arrowHeight
    if edge == .top { card.origin.y += PopoverMetrics.arrowHeight }
    card = card.insetBy(dx: inset, dy: inset)
    let path = Path(roundedRect: card, cornerRadius: PopoverMetrics.cornerRadius - inset, style: .continuous)
    guard let arrowX else { return path }

    let half = PopoverMetrics.arrowWidth / 2
    let range = PopoverMetrics.arrowRange(width: rect.width)
    let x = min(max(arrowX, range.lowerBound), range.upperBound)
    // SwiftUI's y grows downward: a top arrow points toward smaller y.
    let base = edge == .top ? card.minY : card.maxY
    let tip = edge == .top ? rect.minY + inset : rect.maxY - inset
    var arrow = Path()
    arrow.move(to: CGPoint(x: x - half, y: base))
    arrow.addLine(to: CGPoint(x: x, y: tip))
    arrow.addLine(to: CGPoint(x: x + half, y: base))
    arrow.closeSubpath()
    return path.union(arrow)
  }
}
