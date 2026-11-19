# Model pickers and Fast verification — 2026-11-19

Claude implemented the feature. Codex independently reviewed the source, checked installed CLI behavior, found and verified the prompt duplication correction, and ran the final checks.

## Delivered behavior

- Claude and Codex model pickers use the installed CLI's model metadata, with CLI default, saved legacy entries, refresh, loading and failure states.
- Independent Fast preferences default off. Unsupported or unknown capabilities do not request Fast; choosing a model never silently switches it to another one.
- Model metadata and sanitized Codex catalogs persist in owner-only cache files, keyed by executable. Tests cover relaunches, binary changes, corrupt cache and failed refresh. Only model metadata is retained from Claude initialize; account, agents and command data are discarded.
- Settings shows cached entries immediately and queries current metadata once per app session while open. Translation requests use cached/local metadata, without a new model-list network lookup on every translation.
- Settings retains its 460-point width and uses 600-point height to fit the added row. Menus match the existing language menu font.

## Independently verified results

- Baseline: 218 offline tests passed. Final: **257 tests in 38 suites passed**, `/tmp/translate-models-final-offline.log`.
- **Four installed-CLI contract cases passed**: Claude 2.1.327 and Codex 0.167.0, each with Fast off and on, using the real `Translator` with loopback synthetic responses. Model discovery did not create a model response. Codex selected the refreshed catalog's GPT-6.2 Sol, which was absent from its bundled catalog. Requests preserved the selected model, had zero tools and no external agent instructions, and carried the expected speed fields: Claude `speed: fast` or omitted; Codex `service_tier: priority` or omitted for Standard.
- Codex 0.167.0 initially sent the 3,468-character app system prompt twice, failing the strict contract. Empty catalog/base instructions and a single explicit developer instruction fixed it. The final wire assertion requires exactly `[PromptBuilder.systemPrompt, userPrompt]`; the prompt text itself is unchanged.
- Combined final contract and offscreen render run passed: 3 tests in 2 suites, comprising 4 CLI cases, 8 engine/theme render cases and 4 loaded-model render cases. Log: `/tmp/translate-models-final-contract-snapshots.log`. Codex inspected the light/dark images in `/tmp/translate-models-final-snapshots` without interacting with the desktop.
- Signed macOS build passed, `/tmp/translate-models-signed-build.log`; code-signature verification passed before installation.
- `git diff --check` passed. Focused secret-pattern and credential-filename checks found no findings in changed/new files.

The normal offline command is `scripts/test.sh`. Installed-CLI request and render checks are opt-in:

```sh
TEST_RUNNER_TRANSLATION_CLI_CONTRACT_TESTS=1 \
TEST_RUNNER_SETTINGS_SNAPSHOT_DIR=/tmp/translate-models-final-snapshots \
xcodebuild test -project Translate.xcodeproj -scheme Translate \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/translate-models-codex CODE_SIGNING_ALLOWED=NO \
  -only-testing:TranslateTests/CLIWireContractTests \
  -only-testing:TranslateTests/SettingsSnapshotTests
```

## Limits

These checks generate no real model translations and establish no real-provider latency, credit balance or paid Fast entitlement. Model-list queries can contact provider metadata endpoints through the installed CLI. Availability and billing remain controlled by the provider and account. A version-manager shim may not change when its underlying CLI updates; the refresh action retrieves updated metadata in that case. No real desktop source app was operated for this settings change. Reopen Translate to activate the installed build.
