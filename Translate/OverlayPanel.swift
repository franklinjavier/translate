import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
  var state: OverlayState?
  var onCopy: (() -> Void)?
  var onReplace: (() -> Void)?
  var onClose: (() -> Void)?
  var onOpenAccessibility: (() -> Void)?
  var onRetry: (() -> Void)?

  private var hostingView: NSHostingView<TranslationView>?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private let eventTap = OverlayEventTap()

  convenience init() {
    self.init(
      contentRect: NSRect(x: 0, y: 0, width: OverlayMetrics.width, height: 160),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    becomesKeyOnlyIfNeeded = true
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func attach() {
    guard hostingView == nil, let state else { return }
    let root = TranslationView(
      state: state,
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

  func present() {
    presentUnfocused()
  }

  func presentUnfocused() {
    attach()
    relayout()
    positionOnActiveScreen()
    orderFrontRegardless()
    installMonitors()
  }

  func relayout(animated: Bool = false) {
    guard let contentView else { return }
    contentView.layoutSubtreeIfNeeded()
    var size = contentView.fittingSize
    if size.width < OverlayMetrics.width {
      size.width = OverlayMetrics.width
    }
    size.height = min(max(size.height, OverlayMetrics.minHeight), OverlayMetrics.maxHeight)
    let top = frame.maxY == 0 ? size.height : frame.maxY
    var next = frame
    next.size = size
    next.origin.y = top - size.height
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

  private func positionOnActiveScreen() {
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return }
    let visible = screen.visibleFrame
    var next = frame
    next.origin.x = visible.midX - next.width / 2
    next.origin.y = visible.maxY - next.height - visible.height * 0.18
    setFrame(next, display: true)
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

enum OverlayMetrics {
  static let width: CGFloat = 480
  static let minHeight: CGFloat = 112
  static let maxHeight: CGFloat = 640
  static let bodyMaxHeight: CGFloat = 320
}
