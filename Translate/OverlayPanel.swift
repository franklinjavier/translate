import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
  var state: OverlayState?
  var onCopy: (() -> Void)?
  var onReplace: (() -> Void)?
  var onClose: (() -> Void)?
  var onOpenAccessibility: (() -> Void)?
  var onRetry: (() -> Void)?

  let presentation = PopoverPresentation()
  private var hostingView: NSHostingView<TranslationView>?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private let eventTap = OverlayEventTap()

  convenience init() {
    self.init(
      contentRect: NSRect(x: 0, y: 0, width: PopoverMetrics.minWidth, height: 80),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    // The card is always black; pin dark so controls and text stay light in Light Mode too.
    appearance = NSAppearance(named: .darkAqua)
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    becomesKeyOnlyIfNeeded = true
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    // Posted for user drags, not for our own setFrame calls.
    _ = NotificationCenter.default.addObserver(
      forName: NSWindow.willMoveNotification,
      object: self,
      queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.detachFromAnchor() }
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func attach() {
    guard hostingView == nil, let state else { return }
    let root = TranslationView(
      state: state,
      presentation: presentation,
      onCopy: { [weak self] in self?.onCopy?() },
      onReplace: { [weak self] in self?.onReplace?() },
      onOpenAccessibility: { [weak self] in self?.onOpenAccessibility?() },
      onRetry: { [weak self] in self?.onRetry?() }
    )
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = [.intrinsicContentSize]
    contentView = hosting
    hostingView = hosting
  }

  /// Set before presenting; every relayout re-places the panel against it.
  /// Cleared when the user drags the panel so streaming doesn't snap it back.
  private var anchor: OverlayAnchor?

  func presentUnfocused(anchor: OverlayAnchor) {
    prepare(anchor: anchor)
    orderFrontRegardless()
    installMonitors()
  }

  /// Sizes and places the panel for a new invocation without showing it.
  func prepare(anchor: OverlayAnchor, screens: [OverlayPlacement.Screen] = OverlayPanel.currentScreens()) {
    self.anchor = anchor
    // Width only grows within an invocation so streaming text doesn't reflow back and forth.
    presentation.width = 0
    presentation.scrolls = false
    attach()
    relayout(screens: screens)
  }

  func relayout(animated: Bool = false) {
    relayout(animated: animated, screens: Self.currentScreens())
  }

  private func relayout(animated: Bool = false, screens: [OverlayPlacement.Screen]) {
    guard let hostingView, let state else { return }
    let content = state.phase.popoverContent
    presentation.width = max(presentation.width, PopoverSizing.cardWidth(for: content))
    presentation.scrolls = presentation.scrolls
      || PopoverSizing.bodyScrolls(content.text, cardWidth: presentation.width)
    hostingView.layoutSubtreeIfNeeded()
    let size = CGSize(width: presentation.width, height: hostingView.fittingSize.height)

    var next: NSRect
    if let anchor {
      let placement = OverlayPlacement.place(size: size, anchor: anchor, screens: screens)
      next = placement.frame
      presentation.arrowEdge = placement.arrowEdge
      presentation.arrowX = placement.arrowX
    } else {
      // Dragged: keep the card's top edge where the user left it.
      next = frame
      next.size = size
      next.origin.y = frame.maxY - size.height
    }
    hostingView.layoutSubtreeIfNeeded()
    invalidateShadow()
    guard next != frame else { return }
    if animated, isVisible {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        animator().setFrame(next, display: true)
      }
    } else {
      setFrame(next, display: true)
    }
  }

  override func orderOut(_ sender: Any?) {
    removeMonitors()
    super.orderOut(sender)
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDragged {
      detachFromAnchor()
    }
    super.sendEvent(event)
  }

  /// The user moved the panel, so the arrow would no longer point at the selection.
  private func detachFromAnchor() {
    guard anchor != nil || presentation.arrowX != nil else { return }
    anchor = nil
    presentation.arrowX = nil
    invalidateShadow()
  }

  static func currentScreens() -> [OverlayPlacement.Screen] {
    NSScreen.screens.map { OverlayPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
  }

  private func installMonitors() {
    removeMonitors()
    eventTap.onHotkey = { [weak self] action in
      guard let self, self.isVisible else { return false }
      return self.performHotkey(action)
    }
    eventTap.start()
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKey(event) == true ? nil : event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self else { return }
      if !self.frame.contains(NSEvent.mouseLocation) {
        self.onClose?()
      }
    }
  }

  private func removeMonitors() {
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    eventTap.onHotkey = nil
    eventTap.stop()
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard
      let action = OverlayHotkeys.action(
        keyCode: Int64(event.keyCode),
        command: flags.contains(.command),
        option: flags.contains(.option),
        control: flags.contains(.control),
        shift: flags.contains(.shift)
      )
    else { return false }
    return performHotkey(action)
  }

  private func performHotkey(_ action: OverlayHotkey) -> Bool {
    switch action {
    case .close:
      onClose?()
      return true
    case .copy:
      guard state?.currentTranslation() != nil else { return false }
      onCopy?()
      return true
    case .replace:
      guard state?.currentTranslation() != nil else { return false }
      onReplace?()
      return true
    }
  }
}

/// Where the overlay should sit, in AppKit global coordinates (bottom-left origin, y up).
nonisolated enum OverlayAnchor: Equatable, Sendable {
  /// Bounds of the selected text.
  case selection(CGRect)
  /// Mouse location at invocation, used when the app doesn't expose text bounds.
  case point(CGPoint)
}

nonisolated enum OverlayPlacement {
  nonisolated struct Screen: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
  }

  /// Distance from the arrow tip to the selection or pointer.
  static let gap: CGFloat = 4
  static let pointerOffset: CGFloat = 10

  nonisolated struct Placement: Equatable, Sendable {
    var frame: CGRect
    var arrowEdge: PopoverArrowEdge
    /// Arrow center from the panel's left edge, or nil when it can't truthfully point at the anchor.
    var arrowX: CGFloat?
  }

  /// Accessibility reports global rects with a top-left origin on the primary display,
  /// y growing down. AppKit's global space has a bottom-left origin on the same display,
  /// y growing up. Both are global, so one flip against the primary height covers every display.
  static func appKitRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(
      x: rect.origin.x,
      y: primaryScreenHeight - rect.origin.y - rect.height,
      width: rect.width,
      height: rect.height
    )
  }

  /// Rejects the empty or off-screen rects some apps return for AXBoundsForRange.
  static func isUsable(_ rect: CGRect, on screens: [Screen]) -> Bool {
    guard
      rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.width.isFinite, rect.height.isFinite,
      rect.height > 0, rect.width >= 0
    else { return false }
    let probe = CGPoint(x: rect.midX, y: rect.midY)
    return screens.contains { $0.frame.contains(probe) }
  }

  /// Panel placement for `size` (arrow included) next to `anchor`: centered above the selection
  /// when it fits, below when the top would collide, then clamped to the visible area of the
  /// anchor's display. The arrow slides to keep pointing at the anchor after a horizontal clamp
  /// and is dropped when clamping detaches the panel from it.
  /// Called again on every resize, so a growing panel stays attached to the same text.
  static func place(size: CGSize, anchor: OverlayAnchor, screens: [Screen]) -> Placement {
    let target: CGRect
    let spacing: CGFloat
    switch anchor {
    case .selection(let rect):
      target = rect
      spacing = gap
    case .point(let point):
      target = CGRect(origin: point, size: .zero)
      spacing = pointerOffset
    }

    guard let screen = screen(for: target, in: screens) else {
      let frame = CGRect(origin: CGPoint(x: target.midX - size.width / 2, y: target.maxY + spacing), size: size)
      return Placement(frame: frame, arrowEdge: .bottom, arrowX: size.width / 2)
    }
    let visible = screen.visibleFrame

    let aboveY = target.maxY + spacing
    let belowY = target.minY - spacing - size.height
    let edge: PopoverArrowEdge
    if aboveY + size.height <= visible.maxY {
      edge = .bottom
    } else if belowY >= visible.minY {
      edge = .top
    } else {
      // Neither side fits; take the roomier one and let the clamp pull it on screen.
      edge = (visible.maxY - target.maxY) >= (target.minY - visible.minY) ? .bottom : .top
    }
    let preferredY = edge == .bottom ? aboveY : belowY

    let x = clamp(target.midX - size.width / 2, lower: visible.minX, upper: visible.maxX - size.width)
    // A panel taller than the display keeps its top visible.
    let y = size.height > visible.height
      ? visible.maxY - size.height
      : clamp(preferredY, lower: visible.minY, upper: visible.maxY - size.height)
    let frame = CGRect(x: x, y: y, width: size.width, height: size.height)

    let range = PopoverMetrics.arrowRange(width: size.width)
    let arrowX = clamp(target.midX - x, lower: range.lowerBound, upper: range.upperBound)
    let tolerance: CGFloat = 0.5
    let pointsAtTarget = (target.minX - tolerance...target.maxX + tolerance).contains(x + arrowX)
    let attached = abs(y - preferredY) <= tolerance
    return Placement(frame: frame, arrowEdge: edge, arrowX: pointsAtTarget && attached ? arrowX : nil)
  }

  static func screen(for rect: CGRect, in screens: [Screen]) -> Screen? {
    let probe = CGPoint(x: rect.midX, y: rect.midY)
    if let hit = screens.first(where: { $0.frame.contains(probe) }) {
      return hit
    }
    // Points on a display's top or right edge fall outside `contains`; use the nearest display.
    return screens.min {
      squaredDistance(from: probe, to: $0.frame) < squaredDistance(from: probe, to: $1.frame)
    }
  }

  private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return dx * dx + dy * dy
  }

  private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    guard upper >= lower else { return lower }
    return min(max(value, lower), upper)
  }
}
