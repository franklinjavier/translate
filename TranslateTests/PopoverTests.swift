import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Translate

struct PopoverSizingTests {
  static let actions = PopoverContent(text: "Oi", label: "Portuguese", hasActions: true)

  @Test func shortTextUsesFooterWidthWithinBounds() {
    let width = PopoverSizing.cardWidth(for: Self.actions)
    #expect(width >= PopoverMetrics.minWidth)
    #expect(width < 300)
    #expect(width >= PopoverSizing.footerWidth(for: Self.actions))
  }

  @Test func longTextCapsAtMaxWidthAndScrolls() {
    let text = String(repeating: "This sentence keeps going so the popover has to wrap and scroll. ", count: 40)
    let content = PopoverContent(text: text, label: "English", hasActions: true)
    let width = PopoverSizing.cardWidth(for: content)
    #expect(width == PopoverMetrics.maxWidth)
    #expect(PopoverSizing.bodyScrolls(text, cardWidth: width))
    #expect(!PopoverSizing.bodyScrolls("Hello there", cardWidth: width))
  }

  @Test func mediumLineGrowsWithText() {
    let short = PopoverSizing.cardWidth(for: PopoverContent(text: "Hi", label: "English", hasActions: true))
    let medium = PopoverSizing.cardWidth(
      for: PopoverContent(text: "I'll take a look and let you know by tomorrow.", label: "English", hasActions: true)
    )
    #expect(medium > short)
    #expect(medium < PopoverMetrics.maxWidth)
  }

  @Test func longLabelNeverExceedsMaxWidth() {
    let content = PopoverContent(text: "Oi", label: String(repeating: "Portuguese ", count: 20), hasActions: true)
    #expect(PopoverSizing.cardWidth(for: content) == PopoverMetrics.maxWidth)
  }

  @Test func arrowRangeStaysClearOfCorners() {
    let range = PopoverMetrics.arrowRange(width: 300)
    #expect(range.lowerBound == PopoverMetrics.cornerRadius + PopoverMetrics.arrowWidth / 2)
    #expect(range.upperBound == 300 - range.lowerBound)
  }
}

/// Lays out the real panel and hosting view, so ScrollView sizing regressions show up as heights.
@MainActor
struct PopoverHostingTests {
  static let screen = OverlayPlacement.Screen(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
  )
  static let english = TranslationTarget(id: UUID(), label: "English", language: "English")
  static let longText = String(
    repeating: "We reviewed both proposals and will send the final numbers after the meeting. ",
    count: 30
  )

  static func panel(
    _ phase: OverlayState.Phase,
    anchor: OverlayAnchor = .selection(CGRect(x: 600, y: 400, width: 120, height: 18))
  ) -> OverlayPanel {
    let state = OverlayState()
    state.phase = phase
    let panel = OverlayPanel()
    panel.state = state
    panel.prepare(anchor: anchor, screens: [screen])
    return panel
  }

  @Test func shortResultIsCompact() throws {
    let phase = OverlayState.Phase.result(target: Self.english, source: "oi", translation: "Hi")
    let panel = Self.panel(phase)
    let hosting = try #require(panel.contentView)
    #expect(panel.frame.height < 90)
    #expect(panel.frame.height == hosting.fittingSize.height)
    #expect(panel.frame.width == PopoverSizing.cardWidth(for: phase.popoverContent))
    #expect(!panel.presentation.scrolls)
    #expect(panel.presentation.arrowEdge == .bottom)
    #expect(panel.presentation.arrowX != nil)
  }

  @Test func longResultScrollsAtHeightLimit() throws {
    let panel = Self.panel(.result(target: Self.english, source: "x", translation: Self.longText))
    let hosting = try #require(panel.contentView)
    #expect(panel.presentation.scrolls)
    #expect(panel.frame.width == PopoverMetrics.maxWidth)
    #expect(panel.frame.height > PopoverMetrics.bodyMaxHeight)
    #expect(panel.frame.height < PopoverMetrics.bodyMaxHeight + 90)
    #expect(hosting.fittingSize.height == panel.frame.height)
  }

  @Test func loadingAndShortErrorAreCompact() {
    let loading = Self.panel(.loading(target: Self.english, source: ""))
    #expect(loading.frame.height < 90)
    let error = Self.panel(.error(message: "No text selected.", recovery: nil))
    #expect(error.frame.height < 90)
  }

  @Test func accessibilityErrorFitsItsButtons() {
    let panel = Self.panel(.error(message: "macOS has not granted Accessibility.", recovery: .openAccessibility))
    #expect(panel.frame.width == PopoverMetrics.maxWidth)
    #expect(panel.frame.height < 140)
  }

  @Test func footerFitsMeasuredWidth() {
    let footer = NSHostingView(rootView: PopoverFooter(
      label: "Brazilian Portuguese",
      copied: false,
      replaced: false,
      actionsEnabled: true,
      onCopy: {},
      onReplace: {}
    ))
    let measured = PopoverSizing.footerWidth(
      for: PopoverContent(text: "", label: "Brazilian Portuguese", hasActions: true)
    ) - PopoverMetrics.horizontalPadding * 2
    #expect(footer.fittingSize.width <= measured + 1)
  }

  @Test func widthOnlyGrowsWhileStreaming() {
    let panel = Self.panel(.streaming(target: Self.english, source: "x", translation: "I'll take a look and let you"))
    let wide = panel.frame.width
    panel.state?.phase = .result(target: Self.english, source: "x", translation: "OK")
    panel.relayout()
    #expect(panel.frame.width == wide)
  }

  @Test func programmaticMovesKeepTheArrow() {
    let panel = Self.panel(.result(target: Self.english, source: "oi", translation: "Hi"))
    panel.prepare(anchor: .selection(CGRect(x: 200, y: 300, width: 80, height: 18)), screens: [Self.screen])
    #expect(panel.presentation.arrowX != nil)
    #expect(panel.frame.minY == 318 + OverlayPlacement.gap)
  }

  /// Writes PNGs of the real popover for visual review:
  /// `TEST_RUNNER_POPOVER_SNAPSHOT_DIR=/tmp/translate-popover xcodebuild test …`
  @Test(.enabled(if: ProcessInfo.processInfo.environment["POPOVER_SNAPSHOT_DIR"] != nil))
  func writeSnapshots() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POPOVER_SNAPSHOT_DIR"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let portuguese = TranslationTarget(id: UUID(), label: "Português", language: "Brazilian Portuguese")
    let nearTopRight = OverlayAnchor.selection(CGRect(x: 1400, y: 850, width: 30, height: 18))
    let cases: [(String, OverlayState.Phase, OverlayAnchor)] = [
      ("short-above", .result(target: Self.english, source: "", translation: "I reviewed both."), .selection(CGRect(x: 600, y: 400, width: 120, height: 18))),
      ("medium", .result(target: portuguese, source: "", translation: "Vou dar uma olhada e te aviso até amanhã de manhã."), .selection(CGRect(x: 600, y: 400, width: 120, height: 18))),
      ("long-scroll", .result(target: Self.english, source: "", translation: Self.longText), .selection(CGRect(x: 600, y: 400, width: 120, height: 18))),
      ("loading", .loading(target: Self.english, source: ""), .selection(CGRect(x: 600, y: 400, width: 120, height: 18))),
      ("error-accessibility", .error(message: "macOS has not granted Accessibility to this copy of Translate yet. Turn Translate off and on in Accessibility, then click Try again.", recovery: .openAccessibility), .point(CGPoint(x: 700, y: 400))),
      ("below-clamped-right", .result(target: Self.english, source: "", translation: "I'll take a look and let you know."), nearTopRight),
    ]
    for (name, phase, anchor) in cases {
      let panel = Self.panel(phase, anchor: anchor)
      try Self.snapshot(panel, to: directory.appendingPathComponent("\(name).png"))
      print("snapshot \(name): frame=\(panel.frame) edge=\(panel.presentation.arrowEdge) arrowX=\(String(describing: panel.presentation.arrowX))")
    }
    let dragged = Self.panel(.result(target: Self.english, source: "", translation: "I reviewed both."))
    dragged.presentation.arrowX = nil
    try Self.snapshot(dragged, to: directory.appendingPathComponent("dragged-no-arrow.png"))
  }

  /// Renders the panel's own SwiftUI tree over a light backdrop at 2x.
  static func snapshot(_ panel: OverlayPanel, to url: URL) throws {
    let state = try #require(panel.state)
    let margin: CGFloat = 24
    let root = TranslationView(
      state: state,
      presentation: panel.presentation,
      onCopy: {},
      onReplace: {},
      onOpenAccessibility: {},
      onRetry: {}
    )
    .padding(margin)
    .background(Color(white: 0.86))
    let hosting = NSHostingView(rootView: root)
    let size = CGSize(width: panel.frame.width + margin * 2, height: panel.frame.height + margin * 2)
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: url)
  }
}
