# Model pickers and Fast Implementation Plan

**Goal:** Select current installed-CLI models and optional Fast mode without typing IDs or adding translation overhead.

**Architecture:** Background metadata discovery supplies native pickers and per-model compatibility. Existing immutable engine configurations carry an explicit Fast preference to isolated one-shot CLI calls. Reuse sanitized Codex preparations rather than a separate model-list transport.

**Tech stack:** SwiftUI, Swift concurrency, existing posix-spawn process runner, Swift Testing.

## 1. Settings and capability behavior

- [ ] Add failing tests for `claudeFast`/`codexFast` defaulting false when decoding old settings, independent encode/decode, effective compatibility and request configuration snapshots.
- [ ] Extend `AppSettings` and `EngineConfiguration` with defaulted Fast fields, preserving all current initializer call sites and existing model strings.

## 2. Model discovery and cache

- [ ] Add `Translate/CLIModels.swift` for compact model options, parsing Claude initialize and Codex catalogs, preserving default and legacy options. Test malformed metadata, hidden models, duplicate IDs, capabilities and failure preservation with fake executables.
- [ ] Extend `CLIProcess` only as needed for a bounded initialize control request on stdin. Use the existing process-group cancellation and descriptor lifecycle; do not start another process framework or shell pipeline. Test child stdin delivery and cancellation if changed.
- [ ] Run both metadata commands under `CLISandbox` and filtered environments, with no user message. Discard raw Claude account/control metadata immediately after parsing.
- [ ] Cache by resolved executable and refresh only from Settings. Reuse refreshed sanitized Codex catalog for real translations; preserve old immutable preparation files for requests already in flight.

## 3. Native controls and explicit speed

- [ ] Replace model fields in `SettingsView.swift` with native menu pickers, show CLI default and preserved legacy selection, loading/error status and a compact refresh action. Render offline tests without launching installed CLIs (`model.isLive == false`).
- [ ] Add independent Fast switches with compatibility hints and usage-cost copy; no automatic model switching.
- [ ] Pass Claude `--settings` with explicit `fastMode` true/false. Pass Codex explicit service tier Standard/Fast and relevant feature switch, retaining all isolation configuration. Add argv tests for both states and unsupported selections.
- [ ] Update README for model discovery, cache and speed behavior.

## 4. Independent validation and delivery

- [ ] Codex reviews the final diff and runs `scripts/test.sh` with its own derived data and log.
- [ ] Exercise installed CLI payloads against local synthetic endpoints; verify zero tools/external instructions, actual speed fields and preservation of the chosen model. Record any account gating that cannot be validated locally.
- [ ] Render settings offscreen for Claude/Codex in light and dark themes; inspect output without taking desktop focus.
- [ ] Build and verify a signed bundle, stage the installation without restarting the user's current process. Check diff for accidental credentials or private metadata.
- [ ] Commit and push the verified change; report any real-account limitations and the need to reopen Translate.
