# Reliable translation sessions implementation plan

**Goal:** Implement the approved audit fixes without replacing installed CLIs or changing the popover design.

**Architecture:** A captured selection owns its replacement context, a translation session owns cancellation, and one CLI executor owns process resources. Keep concrete boundaries and the existing native UI.

**Tech stack:** Swift 6, AppKit, SwiftUI, Swift Testing, XcodeGen, installed Claude/Codex CLIs.

## 1. Capture and replacement

- [x] Characterize duplicate phrase replacement, changed range/value and failed writes with regression tests that fail on the previous logic.
- [x] Replace static destination fields with a captured selection value. Pass it through AppModel to replacement.
- [x] Validate source range/value before mutation. Compare the expected post-write value or range. Remove first-occurrence fallback and never repeat an accepted write.
- [x] Serialize clipboard transactions, honor throwing cancellation checks around waits and events, and conditionally restore only owned pasteboard versions.
- [x] Track replacement tasks. Report verified, attempted and failed outcomes honestly; avoid multiple replacements and stale-session side effects.
- [x] Invalidate tracked drag geometry on navigation, retaining harmless shortcuts explicitly.

## 2. Engines and process lifetime

- [x] Introduce one runtime engine selection; decode old persisted settings and preserve explicit previous non-Apple engine selection. Update menu, settings, Translator and eval call sites.
- [x] Add fake-executable tests for immediate exit, cancellation before/during execution, ignored termination, concurrent stdout/stderr, nonzero exit and Unicode split across chunks.
- [x] Consolidate process resource ownership and ordered output. Terminate cancelled processes with bounded cleanup; preserve PTY until proven unnecessary.
- [x] Remove content-bearing diagnostics and test a sentinel never appears in traces.
- [x] Keep Codex progress separate from translation, using final-message loading fallback if needed.
- [x] Validate Local MLX completion, length limits, post-delta errors and premature EOF using offline fixtures.

## 3. Coordinator and verification organization

- [x] Prevent live global integrations during hosted test startup.
- [x] Test superseded capture/partial/final, dismissal, cancellation and replacement with controllable asynchronous boundaries.
- [x] Preserve request context for Retry and snapshot engine configuration at request start.
- [x] Split the mixed prompt test file by behavior. Keep all translation examples/checks; move corpus to a resource only if it reduces maintenance without a new framework.
- [x] Remove literal prompt wording assertions while retaining construction and contamination contracts.
- [x] Make screenshot artifact output opt-in. Document an offline verification command separately from live eval.

## 4. Independent Codex verification

- [x] Review every diff and check approved scope, task ownership, cleanup paths and migration semantics independently of Claude's report.
- [x] Run the complete offline suite with a fresh log, then focused stress tests for lifecycle and session ordering.
- [x] Inspect content-free diagnostic paths and sentinel regression tests; check for secrets and accidental generated artifacts in the diff.
- [x] Record net production/test counts honestly, including added safety coverage. Do not force a line reduction or remove required fallback behavior.
- [x] Report verified results and remaining real-editor limits. The user authorized the desktop pause; TextEdit replacement was checked independently and the signed app was updated.

Evidence and limitations: [verification report](../verification/2026-10-15-translation-sessions.md).
