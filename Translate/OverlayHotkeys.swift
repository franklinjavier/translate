import Carbon.HIToolbox
import CoreGraphics
import Foundation

nonisolated enum OverlayHotkey: Equatable, Sendable {
  case copy
  case replace
  case close
}

nonisolated enum OverlayHotkeys {
  static func action(
    keyCode: Int64,
    command: Bool,
    option: Bool,
    control: Bool,
    shift: Bool
  ) -> OverlayHotkey? {
    if keyCode == Int64(kVK_Escape) {
      return .close
    }
    if option || control || shift {
      return nil
    }
    if command, keyCode == Int64(kVK_ANSI_W) {
      return .close
    }
    if command, keyCode == Int64(kVK_ANSI_C) {
      return .copy
    }
    if keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) {
      return .replace
    }
    return nil
  }
}

/// Session-wide key tap so ⌘C / ↩ work while the overlay stays nonactivating.
nonisolated final class OverlayEventTap: @unchecked Sendable {
  var onHotkey: ((OverlayHotkey) -> Bool)?

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  func start() {
    stop()
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: overlayEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return }
    tap = created
    let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    source = loopSource
    CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
  }

  func stop() {
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    tap = nil
    source = nil
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else {
      return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let action = OverlayHotkeys.action(
      keyCode: event.getIntegerValueField(.keyboardEventKeycode),
      command: flags.contains(.maskCommand),
      option: flags.contains(.maskAlternate),
      control: flags.contains(.maskControl),
      shift: flags.contains(.maskShift)
    )
    guard let action else {
      return Unmanaged.passUnretained(event)
    }

    let consumed: Bool
    if Thread.isMainThread {
      consumed = onHotkey?(action) ?? false
    } else {
      consumed = DispatchQueue.main.sync {
        self.onHotkey?(action) ?? false
      }
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
  }
}

nonisolated private func overlayEventTapCallback(
  _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<OverlayEventTap>.fromOpaque(refcon).takeUnretainedValue()
  return tap.handle(type: type, event: event)
}
