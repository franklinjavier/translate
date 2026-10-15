# Translation eval

A live check of real translations from the app's default engine.
It tells you whether a prompt change helped or hurt on cases we care about.
It does not show that quality matches any other product, Raycast AI included.

## What runs

`LiveTranslationEvalTests` in `TranslateTests/PromptBuilderTests.swift` sends each case through the real `Translator`:
the real `PromptBuilder` prompts, the real `OutputSanitizer`, and the default engine from `AppSettings.default`.
Today that's Local MLX at `127.0.0.1:8765` with `LocalMLX.defaultModel`.
Nothing is mocked.
Cases run one at a time, so timings aren't skewed by parallel requests.

There are 39 cases (12 English proofreading, 15 Portuguese to English, 12 English to Portuguese), each with an ID like `en-proof-like-baby`:

| Prefix      | Direction                                   |
| ----------- | ------------------------------------------- |
| `en-proof-` | English proofreading (English in, English out) |
| `pt-en-`    | Brazilian Portuguese work chat to English   |
| `en-pt-`    | English to Brazilian Portuguese             |

They cover:

- the screenshot regression, "Like Notion and Obsidian had a baby.", in all three directions;
- negation, uncertainty, actors and passive voice, present vs. past vs. future;
- questions and requests that must stay questions and requests;
- Markdown and multiline text;
- URLs, code, paths, command flags, and numbers;
- fragments and idioms;
- source text that contains instructions, which must be translated, not obeyed.

### How a case passes

Checks look at meaning, not one exact wording:

- regexes over the output, lowercased and stripped of accents (`nao` matches "Não");
- exact substrings for code, URLs, paths, names, and numbers;
- line counts for Markdown;
- for already natural English, a cap on how much the text may change;
- for every case: no empty output, no echoed `<text>` tags, no "Translation:" labels, no untranslated source, no Spanish words in Portuguese, and the output reads as the target language.

Each case also lists outputs a careful reviewer would accept and outputs they'd reject.
`LiveEvalCaseTests` runs the checks on those lists in every normal test run, with no engine needed.
Every accepted variant must pass and every rejected one must fail.
If a check is too strict or too loose, that test says so before any engine runs.

## Running it

Start the local server:

```bash
local-translate-server start
```

Run the live suite:

```bash
mkdir -p /tmp/translate-eval
TEST_RUNNER_TRANSLATION_LIVE_TESTS=1 \
TEST_RUNNER_TRANSLATION_LIVE_RESULTS=/tmp/translate-eval/after.jsonl \
xcodebuild test -scheme Translate \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TranslateTests/LiveTranslationEvalTests
```

`xcodebuild` passes `TEST_RUNNER_*` variables to the test process without the prefix.

| Variable                                  | Effect                                                                 |
| ----------------------------------------- | ---------------------------------------------------------------------- |
| `TEST_RUNNER_TRANSLATION_LIVE_TESTS=1`    | Turns the suite on. Without it, it's skipped.                          |
| `TEST_RUNNER_TRANSLATION_LIVE_RESULTS`    | Optional. Appends one JSON line per case to this file.                 |
| `TEST_RUNNER_TRANSLATION_LIVE_BACKEND`    | Optional. `local` (default), `claude`, or `codex`.                     |
| `TEST_RUNNER_TRANSLATION_LIVE_MODEL`      | Optional. Overrides the model for that backend.                        |

Once the suite is on, an unreachable server fails every case with "Local MLX isn’t running".
It never skips.

Each case prints a block to the test log:

```
[live-eval] FAIL en-proof-like-baby (en>en) total 812 ms, first token 210 ms, local mlx-community/Qwen3-4B-Instruct-2507-4bit
  source: Like Notion and Obsidian had a baby.
  output: Notion and Obsidian had a baby.
  fail: missing comparison marker /\b(like|as if|as though)\b/
```

Each JSON line has `run`, `prompt` (a fingerprint of the prompt text), `backend`, `model`, `id`, `direction`, `source`, `output`, `passed`, `failures`, `error`, `firstTokenMs`, `totalMs`, `partials`, and `trace`.

## Before and after a prompt change

Record a run with the old prompt, then one with the new prompt, with the same server, model, and cases.
The `prompt` fingerprint in each line tells the runs apart.

Swap only `Translate/PromptBuilder.swift`, so the eval code stays the same.
The old file's prompt-content unit tests may fail; that's why the commands run only the live suite.

For a committed prompt:

```bash
cp Translate/PromptBuilder.swift /tmp/translate-eval/PromptBuilder.after.swift
git show <old-rev>:Translate/PromptBuilder.swift > Translate/PromptBuilder.swift
# run the live suite with TEST_RUNNER_TRANSLATION_LIVE_RESULTS=/tmp/translate-eval/before.jsonl
cp /tmp/translate-eval/PromptBuilder.after.swift Translate/PromptBuilder.swift
# run the live suite with TEST_RUNNER_TRANSLATION_LIVE_RESULTS=/tmp/translate-eval/after.jsonl
```

For the refinement that added this eval, the prompt before it was never committed.
A copy is in `docs/translation-eval/baseline/PromptBuilder.swift`.
Use it in place of `git show`, then delete the folder once you've recorded the baseline.

Compare the runs case by case:

```bash
jq -s -r 'group_by(.id)[]
  | [.[0].id] + map((if .passed then "pass" else "FAIL" end) + " " + (.totalMs | tostring) + "ms")
  | @tsv' /tmp/translate-eval/before.jsonl /tmp/translate-eval/after.jsonl
```

And in total:

```bash
jq -s 'group_by(.prompt) | map({
  prompt: .[0].prompt,
  passed: (map(select(.passed)) | length),
  total: length,
  medianMs: (map(.totalMs // 0) | sort | .[length / 2 | floor])
})' /tmp/translate-eval/before.jsonl /tmp/translate-eval/after.jsonl
```

Run each side twice.
Temperature is 0, but server or model updates can still change outputs; a case that flips between runs is noise, not a result.

Before changing the prompt to fix a failure, read the output.
If it's a valid wording the checks didn't expect, add it to that case's `accepts` and widen the check instead.
Don't paste eval sources or their expected answers into the prompt.
`promptDoesNotQuoteEvalCases` fails if a case source appears in it.

## Scoring by hand

The checks catch specific regressions.
They can't judge whether a translation sounds right.
For that, score outputs by hand.

Export blind rows, with the prompt fingerprint and backend left out and the order shuffled:

```bash
jq -s -r 'map(select(.output != null)) | to_entries | map(.value + {row: .key})
  | sort_by((.row * 7919) % 1009)[]
  | [.row, .id, .source, .output] | @tsv' /tmp/translate-eval/before.jsonl /tmp/translate-eval/after.jsonl \
  > /tmp/translate-eval/blind.tsv
```

Keep the JSONL files to map `row` numbers back to runs after scoring.

Score each row from 1 to 5 on:

| Criterion     | 5                                                                 | 3                                                       | 1                                                        |
| ------------- | ----------------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------- |
| Meaning       | Same facts, actors, negation, certainty, tense, and intent         | Small shift a reader might not notice                   | Says something different, or answers instead of translating |
| Naturalness   | Reads like a fluent coworker wrote it in chat                     | Correct but stiff or literal                            | Awkward or wrong language variant                         |
| Preservation  | Code, URLs, paths, numbers, names, and Markdown untouched          | Formatting changed, content intact                      | Something technical changed or dropped                    |
| Restraint     | Natural input left alone; only real mistakes fixed                 | Some needless rewording                                 | Rewritten, or fragment turned into a different statement  |

A row with Meaning below 4 is a failure, whatever the other scores are.
Report how many rows fail and the mean of each criterion per run.
Don't add the criteria into one number.

To compare with another tool such as Raycast AI, paste the same sources into it by hand.
Save its outputs as JSON lines with the same `id`, `source`, and `output` fields and a different `backend`.
Then score them in the same blind file.
Say a prompt matches another tool only after that blind comparison, and say how many cases and raters it covered.

## Limits

- 39 cases are a regression net, not a benchmark. A few points of pass rate is within noise.
- Regex checks accept the wordings someone thought of. A valid phrasing can fail, and a bad one can slip through if it hits the right words.
- The language check uses `NLLanguageRecognizer` and only runs on six or more words. It's a heuristic.
- The same person wrote the cases and the prompt, so passing can reflect overfitting. Add cases from real failures you see in the app.
- It doesn't measure tone, consistency over long text, or the Apple Translate path.
- One engine at temperature 0 per run. Other models or settings need their own runs.
