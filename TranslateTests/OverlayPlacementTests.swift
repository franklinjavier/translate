import AppKit
import Foundation
import Testing
@testable import Translate

struct OverlayPlacementTests {
  // Primary 1440×900 with a 25pt menu bar; a 1920×1080 display to its right,
  // and one above it (AppKit y > 900) so the AX → AppKit flip is exercised off the primary.
  static let primary = OverlayPlacement.Screen(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
  )
  static let right = OverlayPlacement.Screen(
    frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1080)
  )
  static let above = OverlayPlacement.Screen(
    frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875)
  )
  static let screens = [primary, right, above]
  static let size = CGSize(width: 480, height: 160)

  @Test func flipsAccessibilityRectOnPrimary() {
    // 100pt from the top of the primary display, 20pt tall.
    let rect = OverlayPlacement.appKitRect(
      fromAccessibility: CGRect(x: 200, y: 100, width: 300, height: 20),
      primaryScreenHeight: 900
    )
    #expect(rect == CGRect(x: 200, y: 780, width: 300, height: 20))
  }

  @Test func flipsAccessibilityRectOnSecondaryDisplays() {
    // Display above the primary has negative AX y.
    let aboveRect = OverlayPlacement.appKitRect(
      fromAccessibility: CGRect(x: 100, y: -500, width: 200, height: 18),
      primaryScreenHeight: 900
    )
    #expect(aboveRect == CGRect(x: 100, y: 1382, width: 200, height: 18))
    #expect(Self.above.frame.contains(CGPoint(x: aboveRect.midX, y: aboveRect.midY)))

    // Display to the right, extending below the primary: AX y beyond 900.
    let rightRect = OverlayPlacement.appKitRect(
      fromAccessibility: CGRect(x: 2000, y: 1000, width: 100, height: 20),
      primaryScreenHeight: 900
    )
    #expect(rightRect == CGRect(x: 2000, y: -120, width: 100, height: 20))
    #expect(Self.right.frame.contains(CGPoint(x: rightRect.midX, y: rightRect.midY)))
  }

  @Test func rejectsEmptyAndOffscreenBounds() {
    #expect(!OverlayPlacement.isUsable(.zero, on: Self.screens))
    #expect(!OverlayPlacement.isUsable(CGRect(x: 10, y: 10, width: 40, height: 0), on: Self.screens))
    #expect(!OverlayPlacement.isUsable(CGRect(x: -5000, y: 10, width: 40, height: 20), on: Self.screens))
    #expect(OverlayPlacement.isUsable(CGRect(x: 10, y: 10, width: 0, height: 20), on: Self.screens))
  }

  private func place(
    _ selection: CGRect,
    size: CGSize = OverlayPlacementTests.size,
    screens: [OverlayPlacement.Screen] = OverlayPlacementTests.screens
  ) -> OverlayPlacement.Placement {
    OverlayPlacement.place(size: size, anchor: .selection(selection), screens: screens)
  }

  @Test func placesAboveSelectionCenteredWithArrowDown() {
    let selection = CGRect(x: 200, y: 600, width: 300, height: 20)
    let placement = place(selection)
    #expect(placement.frame.minY == selection.maxY + OverlayPlacement.gap)
    #expect(placement.frame.midX == selection.midX)
    #expect(placement.arrowEdge == .bottom)
    #expect(placement.arrowX == Self.size.width / 2)
    #expect(!placement.frame.intersects(selection))
  }

  @Test func flipsBelowWhenTopWouldCollide() {
    // 25pt under the menu bar: no room above for a 160pt panel.
    let selection = CGRect(x: 200, y: 830, width: 300, height: 20)
    let placement = place(selection)
    #expect(placement.frame.maxY == selection.minY - OverlayPlacement.gap)
    #expect(placement.arrowEdge == .top)
    #expect(placement.arrowX != nil)
    #expect(!placement.frame.intersects(selection))
  }

  @Test func clampsAtRightEdgeAndAimsArrowAtSelection() throws {
    let selection = CGRect(x: 1380, y: 600, width: 40, height: 20)
    let placement = place(selection)
    #expect(placement.frame.maxX == Self.primary.visibleFrame.maxX)
    let arrowX = try #require(placement.arrowX)
    #expect(placement.frame.minX + arrowX == selection.midX)
    #expect(PopoverMetrics.arrowRange(width: Self.size.width).contains(arrowX))
  }

  @Test func clampsAtLeftEdgeAndAimsArrowAtSelection() {
    let selection = CGRect(x: 0, y: 600, width: 100, height: 20)
    let placement = place(selection)
    #expect(placement.frame.minX == Self.primary.visibleFrame.minX)
    #expect(placement.arrowX == selection.midX)
  }

  @Test func hidesArrowWhenCornerKeepsItOffTheSelection() {
    // Selection hugging the screen edge: the arrow can't slide into the rounded corner to reach it.
    let selection = CGRect(x: 2, y: 600, width: 6, height: 20)
    let placement = place(selection)
    #expect(placement.frame.minX == 0)
    #expect(placement.arrowX == nil)
  }

  @Test func hidesArrowWhenClampDetachesPanelVertically() {
    // Neither side fits a near-full-height panel; it is pulled on screen and can't touch the text.
    let placement = place(
      CGRect(x: 200, y: 400, width: 100, height: 20),
      size: CGSize(width: 300, height: 860),
      screens: [Self.primary]
    )
    #expect(Self.primary.visibleFrame.contains(placement.frame))
    #expect(placement.arrowX == nil)
  }

  @Test func staysOnTheSelectionsDisplay() throws {
    let selection = CGRect(x: 3300, y: -100, width: 50, height: 20)
    let placement = place(selection)
    #expect(Self.right.visibleFrame.contains(placement.frame))
    #expect(!placement.frame.intersects(selection))
    let arrowX = try #require(placement.arrowX)
    #expect(placement.frame.minX + arrowX == selection.midX)
  }

  @Test func placesOnDisplayAboveFromAccessibilityRect() {
    let selection = OverlayPlacement.appKitRect(
      fromAccessibility: CGRect(x: 600, y: -400, width: 120, height: 18),
      primaryScreenHeight: 900
    )
    let placement = place(selection)
    #expect(Self.above.visibleFrame.contains(placement.frame))
    #expect(placement.arrowEdge == .bottom)
    #expect(placement.arrowX != nil)
  }

  @Test func keepsBelowMenuBar() {
    // Selection hidden under the menu bar area with nothing above: clamp to visible frame.
    let selection = CGRect(x: 100, y: 880, width: 100, height: 15)
    let placement = place(selection, screens: [Self.primary])
    #expect(Self.primary.visibleFrame.contains(placement.frame))
  }

  @Test func growingPanelKeepsItsEdgeAttachedToSelection() {
    // Above: the bottom edge (arrow tip) stays put as it grows.
    let selection = CGRect(x: 200, y: 300, width: 300, height: 20)
    let small = place(selection)
    let tall = place(selection, size: CGSize(width: 300, height: 420))
    #expect(small.frame.minY == tall.frame.minY)
    #expect(small.frame.midX == tall.frame.midX)

    // Below: the top edge stays put.
    let high = CGRect(x: 200, y: 800, width: 300, height: 20)
    let smallBelow = place(high)
    let tallBelow = place(high, size: CGSize(width: 300, height: 420))
    #expect(smallBelow.frame.maxY == tallBelow.frame.maxY)
  }

  @Test func pointFallbackCentersAboveCursorWithArrow() {
    let placement = OverlayPlacement.place(
      size: Self.size,
      anchor: .point(CGPoint(x: 700, y: 500)),
      screens: Self.screens
    )
    #expect(placement.frame.midX == 700)
    #expect(placement.frame.minY == 500 + OverlayPlacement.pointerOffset)
    #expect(placement.arrowX == Self.size.width / 2)
  }

  @Test func pointOnTopEdgeUsesNearestDisplay() {
    // y == frame.maxY of the right display sits outside `contains`.
    let placement = OverlayPlacement.place(
      size: Self.size,
      anchor: .point(CGPoint(x: 3000, y: 900)),
      screens: [Self.primary, Self.right]
    )
    #expect(Self.right.visibleFrame.contains(placement.frame))
  }

  @Test func panelTallerThanDisplayKeepsTopVisible() {
    let placement = place(
      CGRect(x: 200, y: 400, width: 100, height: 20),
      size: CGSize(width: 480, height: 1000),
      screens: [Self.primary]
    )
    #expect(placement.frame.maxY == Self.primary.visibleFrame.maxY)
    #expect(placement.arrowX == nil)
  }
}
