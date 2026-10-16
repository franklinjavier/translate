import AppKit
import Foundation
import Testing
@testable import Translate

struct OverlayHotkeysTests {
  @Test func enterReplacesWithoutCommand() {
    #expect(
      OverlayHotkeys.action(keyCode: 36, command: false, option: false, control: false, shift: false)
        == .replace
    )
  }

  @Test func commandCCopies() {
    #expect(
      OverlayHotkeys.action(keyCode: 8, command: true, option: false, control: false, shift: false)
        == .copy
    )
  }

  @Test func escapeCloses() {
    #expect(
      OverlayHotkeys.action(keyCode: 53, command: false, option: false, control: false, shift: false)
        == .close
    )
  }

  @Test func shiftEnterIsIgnored() {
    #expect(
      OverlayHotkeys.action(keyCode: 36, command: false, option: false, control: false, shift: true)
        == nil
    )
  }
}
