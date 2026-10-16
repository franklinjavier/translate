# CLI isolation verification — 2026-10-15

This supplements the translation-session reliability verification. Claude implemented the CLI isolation; Codex reviewed the changes and ran independent checks.

## Contract

- Keep the installed Claude/Codex CLIs and their sign-in. Do not edit global configuration or copy credentials.
- Disable tools, MCP, skills, plugins, hooks, agent instructions and session persistence for translation calls.
- Keep the existing translation prompt and selected model. Use low reasoning effort.
- Prepare Codex's bundled local model catalog once per executable per app process. No catalog network refresh; subsequent translations reuse the prepared files.
- Fail without an unrestricted fallback if isolation cannot be configured. Models absent from the bundled catalog require a CLI update or a supported model selection.

## Independent checks

- Offline suite: 217 tests in 34 suites, including real sandbox deny/allow checks, filtered child environment, cancellation, catalog failure, unknown model and reuse across translations.
- Installed CLI contract: Claude Code 2.1.299 and Codex CLI 0.159.0 run through the production `Translator`, against loopback HTTP servers returning synthetic responses. Both engines return the expected translation with no top-level tools, no nested additional tools and no external agent/skill instructions in the captured request. Codex sends exactly the translation system prompt and user prompt as message content. Claude retains its fixed SDK metadata.
- The contract check uses fake local provider credentials and does not send translations to a real model. It does not inspect credential files.
- Signed macOS build and code-signature verification pass. The installed app is updated without interacting with the desktop or restarting the running process.

Normal offline checks: `scripts/test.sh`. Opt-in installed CLI contract check:

```sh
TEST_RUNNER_TRANSLATION_CLI_CONTRACT_TESTS=1 xcodebuild test \
  -project Translate.xcodeproj -scheme Translate \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/translate-cli-isolation-codex \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:TranslateTests/CLIWireContractTests
```

## Limits

The checks establish the request contract for these installed CLI versions, not all future releases. They do not measure real provider latency, billing, subscription authentication or translation quality against a live model. CLI startup, sign-in and fixed SDK overhead remain. A blank Codex model uses the CLI's built-in default because user agent configuration is ignored. Concurrent first calls can prepare duplicate catalogs; only one is retained. Restart Translate to activate the installed build.
