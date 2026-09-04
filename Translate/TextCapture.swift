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
