# Translation session verification

Baseline: `8e38bcb`. Work branch: `codex/harden-translation-sessions`.
Claude Code implemented the changes; Codex reviewed the source and independently executed the checks below.

## Independent results

- Baseline offline suite: 115 tests passed.
- Final offline suite: **205 tests in 32 suites passed** using `DERIVED_DATA=/tmp/translate-hardening-codex TEST_LOG=/tmp/translate-hardening-codex-final.log scripts/test.sh`.
- Process, clipboard, coordinator and capture stress check: **48 tests passed in each of three explicit runs** of `xcodebuild test-without-building`, using the final build. Logs: `/tmp/translate-hardening-codex-stress-1.log` through `-3.log`.
- Final signed Debug build passed. `codesign --verify --deep --strict /Applications/Translate.app` passed after installation.
- `git diff --check` passed. Credential-pattern checks found no private keys, API keys or GitHub tokens in changed and new files. This is a focused check, not a comprehensive security audit.
- All 39 translation evaluation cases retain their original content and order. The prompt is unchanged. The full live quality evaluation was not rerun.

## Regressions verified before correction

Codex added tests against the implementation that exposed clipboard restoration over external updates, an unverified slow paste receiving old clipboard content, a capture error leaving the overlay loading, and replacement moving to an identical phrase in the same field. These assertions failed before their corrections and pass in the final suite. A clipboard-manager read was also covered so it cannot stand in for verification by the intended editor.

The final capture tests use the real capture function with injected app/element boundaries. Six tests failed before the capture snapshot correction, including selection changes during a copy wait, focus changing to another field, an unrelated clipboard value and cancellation on the Accessibility path. These now pass. Logs: `/tmp/translate-hardening-followup-red.log` and `/tmp/translate-hardening-followup-green-focused.log`.

Invalid and overflowing UTF-16 ranges return no capture or splice. The previous substring guard was independently reproduced aborting in an isolated Swift process; the final tests cover these ranges without crashing the test host.

## Real editor check

With the user's permission to pause desktop use, Codex installed the signed app and prepared a fictional TextEdit document containing the same English sentence twice. The user invoked the physical shortcut and Return because synthetic input did not trigger the global shortcut. Codex then read the editor's Accessibility value and confirmed that only the second occurrence changed, while the first sentence and surrounding document remained intact. Focus remained in TextEdit. The configured engine was the installed Codex CLI.

This check exercised the translation coordinator, installed CLI and Accessibility replacement paths. It preceded the last clipboard-capture and invalid-range safeguards; those have offline regression coverage. Copy's UI action and browser-specific clipboard fallback were not exercised in this desktop check.

## Behavior and limits

- Installed Claude and Codex CLIs remain the transports. Claude keeps its PTY. Codex displays its final message instead of exposing transport progress as translation.
- An accepted Accessibility write is never followed by another mutation just because its result cannot be verified.
- Copy fallback leaves the copied source on the clipboard. An unverified paste leaves the translation there. A verified paste restores the previous clipboard only if its write is still current. The pasteboard does not expose reliable writer identity.
- Apps without readable selection bounds or text still require best-effort fallback. When range/value are readable, copied text must match them; apps that transform copied text differently may be refused instead of risking replacement.
- Cancellation terminates the CLI process group with bounded cleanup. A descendant that deliberately leaves that group is outside this guarantee.
- Manual popover sizing and the existing visual design were retained. Replace is disabled while streaming to prevent inserting incomplete output.
- The final signed bundle is installed. The process used in the manual check was preserved so subsequent work did not interrupt the user's desktop; the final executable loads on next launch.

## Size accounting

| Swift source | Baseline | Final | Change |
|---|---:|---:|---:|
| Production | 3,948 lines | 4,708 lines | +760, about 19% |
| Tests | 2,303 lines | 4,066 lines | +1,763, about 77% |

The earlier estimate of a net line reduction was not achieved in this reliability pass. Engine selection, process ownership and selection context are more explicit, while cancellation, validation and test boundaries add production code. Moving the unchanged evaluation corpus into its own Swift file improves navigation without being counted as deletion.
