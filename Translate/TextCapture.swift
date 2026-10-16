import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum TextCapture {
  /// The frontmost app's selection, with what replacing it later needs. Accessibility first;
  /// otherwise a copy through the pasteboard, which stays there as if the user pressed ⌘C.
  static func capture(using clipboard: ClipboardTransactions) async throws -> CaptureResult {
    try await capture(
      using: clipboard,
      frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
      focusedElement: { focusedElement().map(AXSelectionElement.init) }
    )
  }

  /// `capture(using:)` with the frontmost app and focused element supplied by the caller.
  static func capture(
    using clipboard: ClipboardTransactions,
    frontmostPID: () -> pid_t?,
    focusedElement: () -> (any SelectionElement)?
  ) async throws -> CaptureResult {
    try Task.checkCancellation()
    let pid = frontmostPID()
    let element = focusedElement()
    if let element, let text = element.selectedText, !isBlank(text) {
      let range = element.selectedRange
      return result(CapturedSelection(
        text: text,
        source: .accessibility,
        appPID: pid,
        element: element,
        range: range,
        value: range == nil ? nil : element.value
      ))
    }
    guard pid != nil else { return .empty }

    // Copy instead. Everything the copy is checked against is read now, before waiting:
    // while modifiers are held or ⌘C is pending the user can select an identical phrase,
    // edit the text, or switch field or app, and the capture must not follow them there.
    // Some apps expose the range and value but not the selected text; keep them as identity.
    let range = element?.selectedRange
    let value = range == nil ? nil : element?.value
    // With both readable, the copy must be exactly the text they select. Anything else on
    // the pasteboard came from somewhere else.
    var expected: String?
    if let range, let value {
      guard let selected = substring(of: value, in: range), !isBlank(selected) else { return .empty }
      expected = selected
    }
    func isUnchanged() -> Bool {
      guard frontmostPID() == pid else { return false }
      guard let element else { return true }
      return element.isFocused
        && element.selectedRange == range
        && (range == nil || element.value == value)
    }

    guard
      let text = try await clipboard.copySelection(isAppCurrent: isUnchanged),
      !isBlank(text)
    else { return .empty }
    try Task.checkCancellation()
    guard isUnchanged(), expected == nil || text == expected else { return .empty }
    return result(CapturedSelection(
      text: text,
      source: .clipboard,
      appPID: pid,
      element: element,
      range: range,
      value: value
    ))
  }

  /// The UTF-16 `range` of `value`, or nil when it doesn't fit.
  private static func substring(of value: String, in range: NSRange) -> String? {
    let ns = value as NSString
    guard
      range.location >= 0,
      range.length >= 0,
      range.location <= ns.length,
      range.length <= ns.length - range.location
    else { return nil }
    return ns.substring(with: range)
  }

  private static func result(_ selection: CapturedSelection) -> CaptureResult {
    selection.text.count > CapturedSelection.maxCharacters ? .tooLong : .selection(selection)
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      if let role = copyAttribute(current, kAXRoleAttribute) as? String,
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
  /// `isTranslateShortcut` recognizes the app's own shortcuts, which leave the selection alone.
  static func startTrackingSelections(isTranslateShortcut: @escaping (NSEvent) -> Bool) {
    guard dragMonitor == nil else { return }
    translateShortcut = isTranslateShortcut
    dragMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .keyDown]
    ) { event in
      handleTracked(event)
    }
  }

  static var isTrackingSelections: Bool { dragMonitor != nil }

  private static var dragTracker = DragSelectionTracker()
  private static var dragMonitor: Any?
  private static var translateShortcut: (NSEvent) -> Bool = { _ in false }

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
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if DragSelectionTracker.keyChangesSelection(
        keyCode: Int(event.keyCode),
        command: flags.contains(.command),
        option: flags.contains(.option),
        control: flags.contains(.control),
        shift: flags.contains(.shift),
        isTranslateShortcut: translateShortcut(event)
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

  static func focusedElement() -> AXUIElement? {
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
      let rangeRef = copyAttribute(element, kAXSelectedTextRangeAttribute),
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
      let markerRange = copyAttribute(element, "AXSelectedTextMarkerRange"),
      let bounds = rect(from: parameterizedAttribute(element, "AXBoundsForTextMarkerRange", markerRange)),
      // A collapsed range is the caret, not a selection.
      bounds.width > 1
    else { return nil }
    return SelectionGeometry.union([bounds])
  }

  static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = copyAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
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
}

/// A focused Accessibility element read and written as a `SelectionElement`.
final class AXSelectionElement: SelectionElement {
  private let element: AXUIElement

  init(_ element: AXUIElement) {
    self.element = element
  }

  var selectedText: String? {
    TextCapture.copyAttribute(element, kAXSelectedTextAttribute) as? String
  }

  var selectedRange: NSRange? {
    guard
      let value = TextCapture.copyAttribute(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return NSRange(location: range.location, length: range.length)
  }

  var value: String? {
    TextCapture.copyAttribute(element, kAXValueAttribute) as? String
  }

  var isFocused: Bool {
    guard let focused = TextCapture.focusedElement() else { return false }
    return CFEqual(focused, element)
  }

  func setSelectedText(_ text: String) -> Bool {
    AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
  }

  func setValue(_ value: String) -> Bool {
    AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
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

  /// Almost any key can move the caret or edit the text: typing, arrows with any modifier,
  /// ⌘A, ⌘V, ⌘Z, Control-key bindings. So every press forgets the drag except the two known
  /// to leave the selection where it was: plain ⌘C and the app's own translate shortcuts.
  static func keyChangesSelection(
    keyCode: Int,
    command: Bool,
    option: Bool,
    control: Bool,
    shift: Bool,
    isTranslateShortcut: Bool
  ) -> Bool {
    if isTranslateShortcut { return false }
    let plainCommand = command && !option && !control && !shift
    return !(plainCommand && keyCode == kVK_ANSI_C)
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
