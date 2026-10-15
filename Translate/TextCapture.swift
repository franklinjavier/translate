import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

nonisolated private let captureLog = Logger(subsystem: "com.frank.translate", category: "capture")

enum TextCapture {
  private static let maxCharacters = 16_000
  private static var replaceElement: AXUIElement?
  private static var replaceApp: NSRunningApplication?

  static func selectedText() async -> String? {
    replaceElement = nil
    replaceApp = NSWorkspace.shared.frontmostApplication
    if let text = fromAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return clip(text)
    }
    await waitForModifiersToClear()
    return await fromClipboard()
  }

  static func replaceSelectedText(with text: String, matching original: String?) async -> Bool {
    if let element = replaceElement {
      if setSelectedText(element, to: text), valueContains(element, text, original: original) {
        captureLog.info("replace via selectedText")
        return true
      }
      if replaceValueRange(element, with: text), valueContains(element, text, original: original) {
        captureLog.info("replace via selected range")
        return true
      }
      if let original, replaceMatchingValue(element, original: original, replacement: text) {
        captureLog.info("replace via matching value")
        return true
      }
    }

    await waitForModifiersToClear()
    if let app = replaceApp {
      app.activate()
      try? await Task.sleep(for: .milliseconds(80))
    }

    let pasteboard = NSPasteboard.general
    let savedItems = snapshot(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    postCommandV()
    try? await Task.sleep(for: .milliseconds(100))
    restore(savedItems, onto: pasteboard)
    captureLog.info("replace via paste")
    return true
  }

  /// Ancestors checked above the focused element. Browsers keep the page selection on the
  /// AXWebArea a few levels up from the focused link or text run; the walk stops at the window.
  private static let maxAncestorDepth = 8

  /// Screen bounds of the focused element's selection, in Accessibility coordinates
  /// (top-left origin on the primary display). Synchronous so it can run before the overlay shows.
  /// Unions the full-range rect with the first and last character rects, because some apps
  /// (Chromium text fields among them) report only the first line for a multiline range.
  static func selectionBounds() -> CGRect? {
    var element = focusedElement()
    for _ in 0..<maxAncestorDepth {
      guard let current = element else { return nil }
      if let rect = rangeBounds(current) ?? textMarkerBounds(current) {
        return rect
      }
      if let role = attribute(current, kAXRoleAttribute) as? String,
         role == kAXWindowRole || role == kAXApplicationRole {
        return nil
      }
      element = parent(of: current)
    }
    return nil
  }

  /// AppKit-space rect of the last mouse selection in the frontmost app, when nothing has
  /// replaced it since. Used only when Accessibility can't report the selection's bounds.
  static func trackedSelectionRect() -> CGRect? {
    dragTracker.selection(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
  }

  /// Watches mouse selections in other apps from launch, so the first shortcut press already
  /// knows where a drag-selected passage sits even if the pointer has since moved away.
  static func startTrackingSelections() {
    guard dragMonitor == nil else { return }
    dragMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .keyDown]
    ) { event in
      handleTracked(event)
    }
  }

  private static var dragTracker = DragSelectionTracker()
  private static var dragMonitor: Any?

  private static func handleTracked(_ event: NSEvent) {
    let point = NSEvent.mouseLocation
    switch event.type {
    case .leftMouseDown:
      let pid = ownerPID(ofWindow: event.windowNumber)
        ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
      dragTracker.mouseDown(
        at: point,
        pid: pid,
        clickCount: event.clickCount,
        extending: event.modifierFlags.contains(.shift)
      )
    case .leftMouseDragged:
      dragTracker.mouseDragged(to: point)
    case .leftMouseUp:
      dragTracker.mouseUp(at: point)
    case .scrollWheel:
      // The text moved under the remembered rect.
      dragTracker.invalidate()
    case .keyDown:
      let flags = event.modifierFlags
      if DragSelectionTracker.keyChangesSelection(
        keyCode: Int(event.keyCode),
        command: flags.contains(.command),
        control: flags.contains(.control)
      ) {
        dragTracker.invalidate()
      }
    default:
      break
    }
  }

  private static func ownerPID(ofWindow number: Int) -> pid_t? {
    guard
      number > 0,
      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
      let pid = info.first?[kCGWindowOwnerPID as String] as? NSNumber
    else { return nil }
    return pid.int32Value
  }

  private static func focusedElement() -> AXUIElement? {
    if let element = elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
      return element
    }
    // Some apps answer on their own application element but not through the system-wide one.
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return elementAttribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
  }

  private static func parent(of element: AXUIElement) -> AXUIElement? {
    elementAttribute(element, kAXParentAttribute)
  }

  /// Native text views: AXSelectedTextRange plus AXBoundsForRange.
  private static func rangeBounds(_ element: AXUIElement) -> CGRect? {
    guard
      let rangeRef = attribute(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(rangeRef) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
    let rects = SelectionGeometry.probeRanges(for: range).compactMap { probe -> CGRect? in
      var probe = probe
      guard let value = AXValueCreate(.cfRange, &probe) else { return nil }
      return rect(from: parameterizedAttribute(element, kAXBoundsForRangeParameterizedAttribute, value))
    }
    return SelectionGeometry.union(rects)
  }

  /// WebKit and Chromium web content: AXSelectedTextMarkerRange plus AXBoundsForTextMarkerRange.
  /// Both return one rect covering every line of the range.
  private static func textMarkerBounds(_ element: AXUIElement) -> CGRect? {
    guard
      let markerRange = attribute(element, "AXSelectedTextMarkerRange"),
      let bounds = rect(from: parameterizedAttribute(element, "AXBoundsForTextMarkerRange", markerRange)),
      // A collapsed range is the caret, not a selection.
      bounds.width > 1
    else { return nil }
    return SelectionGeometry.union([bounds])
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private static func parameterizedAttribute(
    _ element: AXUIElement,
    _ name: String,
    _ parameter: CFTypeRef
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success
    else { return nil }
    return value
  }

  private static func rect(from value: CFTypeRef?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
    return rect
  }

  static var isTrusted: Bool {
    AXIsProcessTrustedWithOptions(nil)
  }

  @discardableResult
  static func promptForTrust() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  static func openAccessibilitySettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    if let url {
      NSWorkspace.shared.open(url)
    }
  }

  private static func setSelectedText(_ element: AXUIElement, to text: String) -> Bool {
    AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFTypeRef
    ) == .success
  }

  private static func replaceValueRange(_ element: AXUIElement, with text: String) -> Bool {
    var rangeRef: CFTypeRef?
    var valueRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &rangeRef
      ) == .success,
      let rangeRef,
      CFGetTypeID(rangeRef) == AXValueGetTypeID()
    else { return false }

    var range = CFRange()
    guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return false }
    guard
      AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
      let current = valueRef as? String,
      let next = SelectedTextSplicer.splice(
        value: current,
        utf16Location: Int(range.location),
        utf16Length: Int(range.length),
        insertion: text
      )
    else { return false }

    return AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      next as CFTypeRef
    ) == .success
  }

  private static func replaceMatchingValue(
    _ element: AXUIElement,
    original: String,
    replacement: String
  ) -> Bool {
    guard
      let current = readValue(element),
      let next = SelectedTextSplicer.replacingFirstOccurrence(
        of: original,
        in: current,
        with: replacement
      )
    else { return false }
    let status = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      next as CFTypeRef
    )
    return status == .success && valueContains(element, replacement, original: original)
  }

  private static func readValue(_ element: AXUIElement) -> String? {
    var valueRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
    else { return nil }
    return valueRef as? String
  }

  private static func valueContains(_ element: AXUIElement, _ replacement: String, original: String?) -> Bool {
    guard let value = readValue(element), value.contains(replacement) else { return false }
    guard let original, original != replacement else { return true }
    return !value.contains(original)
  }

  private static func fromAccessibility() -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWide,
      kAXFocusedUIElementAttribute as CFString,
      &focused
    ) == .success, let focused else {
      return nil
    }

    let element = focused as! AXUIElement
    replaceElement = element
    var selected: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      &selected
    ) == .success else {
      return nil
    }
    return selected as? String
  }

  private static func fromClipboard() async -> String? {
    let pasteboard = NSPasteboard.general
    let savedItems = snapshot(pasteboard)
    let changeCount = pasteboard.changeCount

    postCommandC()

    var changed = pasteboard.changeCount != changeCount
    if !changed {
      for _ in 0..<12 {
        try? await Task.sleep(for: .milliseconds(8))
        if pasteboard.changeCount != changeCount {
          changed = true
          break
        }
      }
    }

    let text = changed ? pasteboard.string(forType: .string) : nil
    restore(savedItems, onto: pasteboard)

    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return clip(text)
  }

  private static func waitForModifiersToClear() async {
    for _ in 0..<20 {
      let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
      if held.isEmpty { return }
      try? await Task.sleep(for: .milliseconds(8))
    }
  }

  private static func postCommandC() {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    let keyCode = CGKeyCode(kVK_ANSI_C)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  private static func postCommandV() {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    let keyCode = CGKeyCode(kVK_ANSI_V)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
    guard let items = pasteboard.pasteboardItems else { return [] }
    return items.map { item in
      let clone = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          clone.setData(data, forType: type)
        }
      }
      return clone
    }
  }

  private static func restore(_ items: [NSPasteboardItem], onto pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }

  private static func clip(_ text: String) -> String {
    guard text.count > maxCharacters else { return text }
    return String(text.prefix(maxCharacters))
  }
}

nonisolated enum SelectionGeometry {
  /// Full range, then first and last character, so a first-line-only full rect still
  /// reaches the selection's bottom line.
  static func probeRanges(for range: CFRange) -> [CFRange] {
    guard range.length > 1 else { return [range] }
    return [
      range,
      CFRange(location: range.location, length: 1),
      CFRange(location: range.location + range.length - 1, length: 1),
    ]
  }

  /// Union of the rects an app returned, ignoring the empty or non-finite ones.
  static func union(_ rects: [CGRect]) -> CGRect? {
    rects
      .filter {
        $0.origin.x.isFinite && $0.origin.y.isFinite
          && $0.width.isFinite && $0.height.isFinite
          && $0.height > 0 && $0.width >= 0
      }
      .reduce(CGRect?.none) { partial, rect in partial?.union(rect) ?? rect }
  }

  /// Rect to anchor the popover on, both inputs in AppKit coordinates. Accessibility wins;
  /// a tracked drag that overlaps it widens it (covers apps that report one line only),
  /// while a drag elsewhere is stale and ignored.
  static func anchorRect(accessibility: CGRect?, drag: CGRect?) -> CGRect? {
    switch (accessibility, drag) {
    case let (ax?, drag?):
      let reach = DragSelectionTracker.lineAllowance
      return ax.insetBy(dx: -reach, dy: -reach).intersects(drag) ? ax.union(drag) : ax
    case let (ax?, nil):
      return ax
    case let (nil, drag?):
      return drag
    case (nil, nil):
      return nil
    }
  }
}

/// Remembers the last mouse selection in AppKit coordinates. Endpoints are only pointer
/// positions somewhere inside the first and last lines, so the rect grows by `lineAllowance`
/// above and below to clear those lines. Only press, drag and release update it; plain
/// pointer movement afterwards never does.
nonisolated struct DragSelectionTracker {
  /// Half a generous text line: enough to clear the line the pointer was on.
  static let lineAllowance: CGFloat = 16
  static let minimumDrag: CGFloat = 4

  private(set) var rect: CGRect?
  private(set) var pid: pid_t?
  /// Where the selection was anchored, kept so shift-click can extend it.
  private var origin: CGPoint?
  private var pressed = false
  private var dragged = false
  private var extending = false

  mutating func mouseDown(at point: CGPoint, pid: pid_t?, clickCount: Int, extending: Bool) {
    pressed = true
    dragged = false
    if extending, rect != nil, origin != nil, pid == self.pid {
      self.extending = true
      return
    }
    self.extending = false
    self.pid = pid
    origin = point
    // Double-click selects a word, triple-click a line, both around the pointer.
    rect = clickCount >= 2 ? Self.span(point, point) : nil
  }

  mutating func mouseDragged(to point: CGPoint) {
    guard pressed, let origin else { return }
    if hypot(point.x - origin.x, point.y - origin.y) >= Self.minimumDrag {
      dragged = true
    }
  }

  mutating func mouseUp(at point: CGPoint) {
    guard pressed, let origin else { return }
    pressed = false
    if dragged || extending {
      rect = Self.span(origin, point)
    }
    extending = false
  }

  mutating func invalidate() {
    self = DragSelectionTracker()
  }

  func selection(frontmostPID: pid_t?) -> CGRect? {
    guard let rect, let pid, pid == frontmostPID, !pressed else { return nil }
    return rect
  }

  /// Typing, plain or shift arrows, and Select All change the selection without the mouse.
  /// Other Command and Control shortcuts (Copy, the translate hotkey) leave it alone.
  static func keyChangesSelection(keyCode: Int, command: Bool, control: Bool) -> Bool {
    if command { return keyCode == kVK_ANSI_A }
    return !control
  }

  static func span(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(
      x: min(a.x, b.x),
      y: min(a.y, b.y) - lineAllowance,
      width: abs(a.x - b.x),
      height: abs(a.y - b.y) + lineAllowance * 2
    )
  }
}

nonisolated enum SelectedTextSplicer {
  static func splice(
    value: String,
    utf16Location: Int,
    utf16Length: Int,
    insertion: String
  ) -> String? {
    let ns = value as NSString
    guard
      utf16Location >= 0,
      utf16Length >= 0,
      utf16Location <= ns.length,
      utf16Location + utf16Length <= ns.length
    else { return nil }
    return ns.replacingCharacters(
      in: NSRange(location: utf16Location, length: utf16Length),
      with: insertion
    )
  }

  static func replacingFirstOccurrence(of original: String, in value: String, with insertion: String) -> String? {
    guard let range = value.range(of: original) else { return nil }
    return value.replacingCharacters(in: range, with: insertion)
  }
}
