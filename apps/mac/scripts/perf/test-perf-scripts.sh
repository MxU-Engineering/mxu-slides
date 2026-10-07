#!/bin/bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp -R "$HERE/fixtures/test-run" "$SCRATCH/run"
REPORT="$(python3 "$HERE/analyze.py" "$SCRATCH/run" "$HERE/fixtures/test-run-baseline.json")"
STATUS=$?

passed=0
failed=0
expect() {
  if [[ "$1" == *"$2"* ]]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: missing: $2"; fi
}
check() {
  if [ "$1" = "$2" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $3: $1 != $2"; fi
}

expect "$REPORT" "MxU Slides perf check: fixture (abc1234567) on Test Mac"
expect "$REPORT" "animateIdle.mainBusy                       5         1       5  ok"
expect "$REPORT" "playback.mainBusy                         25        12      20  OVER"
expect "$REPORT" "playback.timelineBodiesPerSecond          30         -       5  OVER"
expect "$REPORT" "render.renderBusy                          8       7.9      12  ok"
expect "$REPORT" "drag.firstLongestPass                    524         -     600  ok"
expect "$REPORT" "drag.laterLongestPass                    122       122     180  ok"
expect "$REPORT" "drag.laterDecodeSamples                   42         0      20  OVER"
expect "$REPORT" "drag.laterMainBusy                        15         9      15  ok"
expect "$REPORT" "resize.longestPass                       157         -     200  ok"
expect "$REPORT" "alarms.storms                              1         -       0  OVER"
expect "$REPORT" "FAIL — results:"
check "$STATUS" "1" "a run over a limit exits 1"
check "$(python3 -c "import json; print(json.load(open('$SCRATCH/run/results.json'))['steps']['drag'][0]['passes'])")" \
  "[524.0, 150.0]" "passes are read inside the step's window only"

python3 - "$SCRATCH/loose.json" <<'PY'
import json, sys
json.dump({"thresholds": {"playback.mainBusy": 100}}, open(sys.argv[1], "w"))
PY
python3 "$HERE/analyze.py" "$SCRATCH/run" "$SCRATCH/loose.json" >/dev/null
check "$?" "0" "a run under every limit exits 0"

SECRET="$(python3 "$HERE/make-library.py" mint "$SCRATCH/tokens.json")"
check "$(python3 - "$SCRATCH/tokens.json" "$SECRET" <<'PY'
import hashlib, json, sys
token = json.load(open(sys.argv[1]))[0]
salt, digest = token["secretRecord"].split("$")
ok = hashlib.sha256(bytes.fromhex(salt) + sys.argv[2].encode()).hexdigest() == digest
print(ok and token["scope"] == "edit" and token["prefix"] == sys.argv[2][:9] and len(salt) == 32)
PY
)" "True" "the minted record verifies"

echo "perf scripts: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
