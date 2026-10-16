#!/bin/bash
# Offline build and test. No live models, signing, installation or screenshots:
# the live eval and snapshot writers stay off even if their variables are set.
# Extra arguments go to xcodebuild, e.g. -only-testing:TranslateTests/CLIProcessTests
set -euo pipefail
cd "$(dirname "$0")/.."

derived_data="${DERIVED_DATA:-/tmp/translate-offline-tests}"
log="${TEST_LOG:-$derived_data.log}"

xcodegen generate --quiet
status=0
env -u TRANSLATION_LIVE_TESTS -u TEST_RUNNER_TRANSLATION_LIVE_TESTS \
  -u TRANSLATION_CLI_CONTRACT_TESTS -u TEST_RUNNER_TRANSLATION_CLI_CONTRACT_TESTS \
  -u SETTINGS_SNAPSHOT_DIR -u TEST_RUNNER_SETTINGS_SNAPSHOT_DIR \
  -u POPOVER_SNAPSHOT_DIR -u TEST_RUNNER_POPOVER_SNAPSHOT_DIR \
  xcodebuild test \
    -project Translate.xcodeproj \
    -scheme Translate \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" > "$log" 2>&1 || status=$?

grep -E '^✘ |^[✔✘] Test run with |^\S+:[0-9]+:[0-9]+: error:' "$log" || true
echo "Full log: $log"
exit "$status"
