# Compact translation popover implementation plan

**Goal:** Replace the fixed translation card with the approved compact anchored popover.

**Architecture:** Keep the nonactivating NSPanel and current capture/keyboard flow. Separate pure sizing and placement geometry from SwiftUI presentation; expose resolved arrow edge and offset to the view. Measure text with platform fonts, bound width and height, and explicitly size the hosting view so ScrollView cannot demand unused space.

**Tech stack:** Swift 6, AppKit, SwiftUI, Swift Testing.

## Tasks

- [x] Update `Translate/OverlayPanel.swift` placement to prefer above, flip below, clamp to visible screen, and return arrow attachment geometry. Keep existing coordinate conversion and fallback behavior.
- [x] Update `Translate/TranslationView.swift` to render translation first, compact language/actions footer, hidden original, rounded black body with attached arrow. Bound long content and handle loading/error states.
- [x] Add sizing logic in existing files or a focused new Swift file if needed. Use actual fonts and preserve sensible footer minimum width. Keep width stable during streaming where possible; reset for each invocation.
- [x] Update `TranslateTests/PromptBuilderTests.swift` or focused new tests for above/below placement, edge clamping and arrow alignment, short versus long sizes, and hosting-view fitting heights. Preserve earlier prompt tests.
- [x] Codex reviews the complete diff and runs xcodebuild test with ad-hoc signing for the test host, then a normal signed build. Inspect actual rendered short/long popovers and correct defects before installation.
- [x] Install a verified signed bundle in `/Applications/Translate.app` and restart it. Report evidence and remaining limits without claiming unverified UI flows.

No dependency additions, commits, prompt changes, or unrelated refactors are needed.

## Verified result

Codex independently ran the full suite: 63 tests passed. The optional hosting/snapshot suite also passed, including seven rendered states. A separate executable compiled from the real view/panel sources confirmed a short result at 240×75 pt, long content at 480×316 pt, top-edge flip and loading-to-result resizing. Normal signed build succeeded; signature verification passed before and after installation in `/Applications/Translate.app`.
