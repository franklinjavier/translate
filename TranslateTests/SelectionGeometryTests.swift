import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Translate

struct SelectionGeometryTests {
  @Test func probesFullRangeAndBothEndCharacters() {
    let probes = SelectionGeometry.probeRanges(for: CFRange(location: 10, length: 40))
    #expect(probes.map(\.location) == [10, 10, 49])
    #expect(probes.map(\.length) == [40, 1, 1])
  }

  @Test func singleCharacterProbesOnce() {
    let probes = SelectionGeometry.probeRanges(for: CFRange(location: 3, length: 1))
    #expect(probes.count == 1)
  }

  @Test func unionReachesLastLineWhenFullRectIsFirstLineOnly() {
    // Accessibility space: y grows down. The app reports only line one for the full range.
    let firstLineOnly = CGRect(x: 100, y: 200, width: 500, height: 20)
    let firstChar = CGRect(x: 300, y: 200, width: 8, height: 20)
    let lastChar = CGRect(x: 140, y: 260, width: 8, height: 20)
    let union = SelectionGeometry.union([firstLineOnly, firstChar, lastChar])
    #expect(union == CGRect(x: 100, y: 200, width: 500, height: 80))
  }

  @Test func unionIgnoresEmptyAndNonFiniteRects() {
    let line = CGRect(x: 10, y: 10, width: 50, height: 18)
    #expect(SelectionGeometry.union([.zero, line, CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)]) == line)
    #expect(SelectionGeometry.union([.zero]) == nil)
  }

  @Test func overlappingDragWidensAccessibilityRect() {
    let ax = CGRect(x: 100, y: 500, width: 400, height: 20)
    let drag = CGRect(x: 120, y: 440, width: 300, height: 90)
    #expect(SelectionGeometry.anchorRect(accessibility: ax, drag: drag) == ax.union(drag))
  }

  @Test func distantDragIsStaleNextToAccessibilityRect() {
    let ax = CGRect(x: 100, y: 500, width: 400, height: 20)
    let drag = CGRect(x: 900, y: 100, width: 50, height: 40)
    #expect(SelectionGeometry.anchorRect(accessibility: ax, drag: drag) == ax)
    #expect(SelectionGeometry.anchorRect(accessibility: nil, drag: drag) == drag)
    #expect(SelectionGeometry.anchorRect(accessibility: nil, drag: nil) == nil)
  }
}

struct DragSelectionTrackerTests {
  let allowance = DragSelectionTracker.lineAllowance

  @Test func multilineDragCoversFirstAndLastLine() {
    var tracker = DragSelectionTracker()
    // AppKit space: dragging down the page lowers y.
    tracker.mouseDown(at: CGPoint(x: 400, y: 600), pid: 42, clickCount: 1, extending: false)
    tracker.mouseDragged(to: CGPoint(x: 300, y: 560))
    tracker.mouseDragged(to: CGPoint(x: 150, y: 520))
    tracker.mouseUp(at: CGPoint(x: 150, y: 520))
    let rect = tracker.selection(frontmostPID: 42)
    #expect(rect == CGRect(x: 150, y: 520 - allowance, width: 250, height: 80 + allowance * 2))
  }

  @Test func rightToLeftAndUpwardDragGivesSameRect() {
    var forward = DragSelectionTracker()
    forward.mouseDown(at: CGPoint(x: 100, y: 300), pid: 1, clickCount: 1, extending: false)
    forward.mouseDragged(to: CGPoint(x: 260, y: 240))
    forward.mouseUp(at: CGPoint(x: 260, y: 240))

    var backward = DragSelectionTracker()
    backward.mouseDown(at: CGPoint(x: 260, y: 240), pid: 1, clickCount: 1, extending: false)
    backward.mouseDragged(to: CGPoint(x: 100, y: 300))
    backward.mouseUp(at: CGPoint(x: 100, y: 300))

    #expect(forward.selection(frontmostPID: 1) == backward.selection(frontmostPID: 1))
  }

  @Test func plainClickLeavesNoSelectionAndClearsThePreviousOne() {
    var tracker = draggedTracker(pid: 7)
    #expect(tracker.selection(frontmostPID: 7) != nil)
    tracker.mouseDown(at: CGPoint(x: 10, y: 10), pid: 7, clickCount: 1, extending: false)
    tracker.mouseUp(at: CGPoint(x: 11, y: 10))
    #expect(tracker.selection(frontmostPID: 7) == nil)
  }

  @Test func tinyJitterIsNotADrag() {
    var tracker = DragSelectionTracker()
    tracker.mouseDown(at: CGPoint(x: 10, y: 10), pid: 7, clickCount: 1, extending: false)
    tracker.mouseDragged(to: CGPoint(x: 12, y: 11))
    tracker.mouseUp(at: CGPoint(x: 12, y: 11))
    #expect(tracker.selection(frontmostPID: 7) == nil)
  }

  @Test func selectionIsScopedToTheAppItWasMadeIn() {
    let tracker = draggedTracker(pid: 7)
    #expect(tracker.selection(frontmostPID: 8) == nil)
    #expect(tracker.selection(frontmostPID: nil) == nil)
  }

  @Test func stragglingDragEventsAfterReleaseDoNotMoveTheRect() {
    var tracker = draggedTracker(pid: 7)
    let before = tracker.selection(frontmostPID: 7)
    tracker.mouseDragged(to: CGPoint(x: 900, y: 900))
    tracker.mouseUp(at: CGPoint(x: 900, y: 900))
    #expect(tracker.selection(frontmostPID: 7) == before)
  }

  @Test func doubleClickSelectsAroundThePointer() {
    var tracker = DragSelectionTracker()
    tracker.mouseDown(at: CGPoint(x: 50, y: 50), pid: 3, clickCount: 2, extending: false)
    tracker.mouseUp(at: CGPoint(x: 50, y: 50))
    #expect(tracker.selection(frontmostPID: 3) == CGRect(x: 50, y: 50 - allowance, width: 0, height: allowance * 2))
  }

  @Test func shiftClickExtendsFromTheOriginalAnchor() {
    var tracker = draggedTracker(pid: 7)
    tracker.mouseDown(at: CGPoint(x: 80, y: 100), pid: 7, clickCount: 1, extending: true)
    tracker.mouseUp(at: CGPoint(x: 80, y: 100))
    #expect(tracker.selection(frontmostPID: 7) == DragSelectionTracker.span(CGPoint(x: 400, y: 600), CGPoint(x: 80, y: 100)))
  }

  @Test func invalidateForgetsTheSelection() {
    var tracker = draggedTracker(pid: 7)
    tracker.invalidate()
    #expect(tracker.selection(frontmostPID: 7) == nil)
  }

  @Test func onlySelectionChangingKeysInvalidate() {
    #expect(DragSelectionTracker.keyChangesSelection(keyCode: kVK_LeftArrow, command: false, control: false))
    #expect(DragSelectionTracker.keyChangesSelection(keyCode: kVK_ANSI_A, command: true, control: false))
    #expect(!DragSelectionTracker.keyChangesSelection(keyCode: kVK_ANSI_C, command: true, control: false))
    #expect(!DragSelectionTracker.keyChangesSelection(keyCode: kVK_ANSI_I, command: true, control: false))
    #expect(!DragSelectionTracker.keyChangesSelection(keyCode: kVK_ANSI_E, command: false, control: true))
  }

  @Test func popoverClearsEveryLineOfATrackedSelection() {
    let tracker = draggedTracker(pid: 7)
    let rect = tracker.selection(frontmostPID: 7)!
    let screen = OverlayPlacement.Screen(
      frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )
    let placement = OverlayPlacement.place(
      size: CGSize(width: 300, height: 120),
      anchor: .selection(rect),
      screens: [screen]
    )
    #expect(placement.frame.minY >= rect.maxY || placement.frame.maxY <= rect.minY)
  }

  private func draggedTracker(pid: pid_t) -> DragSelectionTracker {
    var tracker = DragSelectionTracker()
    tracker.mouseDown(at: CGPoint(x: 400, y: 600), pid: pid, clickCount: 1, extending: false)
    tracker.mouseDragged(to: CGPoint(x: 150, y: 520))
    tracker.mouseUp(at: CGPoint(x: 150, y: 520))
    return tracker
  }
}
