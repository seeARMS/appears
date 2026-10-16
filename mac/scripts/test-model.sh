#!/bin/bash
# Real inference, only on demo data. Fails instead of reporting skipped tests
# as passing when the model or CLI is missing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export APPEARS_MODEL=${APPEARS_MODEL:-$ROOT/mac/Models/appears-model}
for file in model.safetensors vision.safetensors; do
  [[ -s "$APPEARS_MODEL/$file" ]] || { echo 'Model tests did not run: prepare the model with mac/scripts/fetch-model.sh or set APPEARS_MODEL.' >&2; exit 1; }
done
cd "$ROOT/mac/Packages/AppearsModel"
DERIVED="$ROOT/mac/build/ModelCheckDerivedData"
xcodebuild -scheme appears -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -configuration Release ENABLE_TESTABILITY=YES build -quiet
export APPEARS_BIN="$DERIVED/Build/Products/Release/appears"
export TEST_RUNNER_APPEARS_BIN="$APPEARS_BIN"
export TEST_RUNNER_APPEARS_MODEL="$APPEARS_MODEL"
[[ -x "$APPEARS_BIN" ]]
RESULT="$DERIVED/ModelTests.xcresult"
rm -rf "$RESULT"
xcodebuild test -scheme AppearsModel-Package -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -configuration Release ENABLE_TESTABILITY=YES \
  -resultBundlePath "$RESULT" -quiet
xcrun xcresulttool get test-results summary --path "$RESULT" > "$DERIVED/model-test-summary.json"
python3 -I - "$DERIVED/model-test-summary.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get("skippedTests", 0) or result.get("failedTests", 0) or result.get("passedTests", 0) < 3:
    raise SystemExit("Model coverage is incomplete: all three inference/MCP tests must run and pass, with none skipped.")
print(f"Model tests: {result['passedTests']} passed, none skipped.")
PY
cd "$ROOT"
"$APPEARS_BIN" eval --verbose --model "$APPEARS_MODEL"
