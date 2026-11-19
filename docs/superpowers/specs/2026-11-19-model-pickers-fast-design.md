# Model pickers and Fast mode

Approved by Frank in chat on 2026-11-19: replace each CLI's free-text model field with current model options, preserve CLI default and existing selections, and add an independent Fast switch per engine, off initially and available only on compatible models.

## Behavior

- Keep the compact native settings layout, system appearance and editable CLI path.
- Read Claude's supported models and `supportsFastMode` through its SDK initialize control response without a user message. Read Codex's refreshed model catalog through `debug models`, filtering hidden/internal entries from the picker.
- Query metadata in the background while Settings is open; cache by resolved executable, offer refresh, preserve successful options on failure and retain any saved legacy model as a selected entry. Never replace a saved model automatically.
- Retain the filtered model metadata and sanitized Codex catalog across app launches. A newly selected model and saved Fast preference must work after restarting Translate without first reopening Settings; metadata cache failures must still fail closed rather than restoring coding-agent context.
- Include `CLI default`, using metadata for compatibility when available. Keep the current selection usable while metadata is loading or fails.
- Fast is stored separately for Claude and Codex. Effective Fast is false for unsupported/unknown models and engines. Changing settings does not alter an in-flight translation's configuration.
- Show a short usage-cost hint. Claude Fast uses usage credits outside subscription limits. Do not change global CLI settings, buy credits, or switch models to enable Fast.

## Transport and isolation

Claude receives explicit per-invocation `--settings` for Fast on/off, with all existing isolation flags retained. Codex receives explicit Standard/Fast service configuration; its model's own catalog default must not enable Fast when the switch is off. Prepare the selected model's sanitized catalog from the same refreshed metadata used by the picker, so newly available models work even when absent from the bundled catalog. A translation without loaded metadata retains the local bundled fallback and fails closed for unknown models.

Codex catalog/base instructions are cleared and the app prompt is supplied once as developer instructions. The installed-CLI contract requires exactly one copy of the unchanged translation prompt plus the user text.

Only model names, IDs and relevant capabilities are retained from Claude initialize; account, commands, agents and raw response contents are not persisted or logged. Metadata queries and real-CLI loopback validation do not generate real model responses. Do not add HTTP model transports, tools, skills, plugins or project instructions to translation calls.

## Verification

Tests cover old settings decoding with Fast off, independent preferences and configuration snapshots, model parsing/filtering/default/legacy behavior, refresh failure and executable changes, native settings rendering, and actual child launch arguments. Existing real-CLI loopback tests must keep asserting zero tools and no external instructions, with explicit checks for Standard/Fast requests where the installed CLI permits local verification. Do not claim real account entitlement or paid Fast throughput based on loopback tests.
