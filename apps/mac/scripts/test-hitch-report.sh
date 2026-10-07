#!/bin/bash
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPTS/fixtures/hitch-report"
REPORT="$(python3 "$SCRIPTS/hitch-report.py" "$FIXTURE")" || { echo "FAIL: hitch-report.py exited $?"; exit 1; }
SHIFTED="$(python3 "$SCRIPTS/hitch-report.py" --utc-offset -4 "$FIXTURE/breadcrumbs-2026-09-22.log")"
EMPTY="$(python3 "$SCRIPTS/hitch-report.py" "$SCRIPTS" 2>&1)"
EMPTY_STATUS=$?

passed=0
failed=0
expect() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: missing: $needle"
  fi
}

expect "$REPORT" "report.json: app_version 0.1.0, app_build 4210, app_commit 1a2b3c4d5e"
expect "$REPORT" "== 2026-09-22 (30 crumbs)"
expect "$REPORT" "launches: 1 × v0.1.0 (4210) commit 1a2b3c4d5e, image uuid 5B1E0F4A-0000-4000-8000-00000000ABCD (10:00Z)"
expect "$REPORT" "hitches: 4, blocked 6.0 s total, worst 4000 ms"
expect "$REPORT" "left out as sleep (1 h or longer): 1"
expect "$REPORT" "250-500 ms       2  50%"
expect "$REPORT" "1-3 s            1  25%"
expect "$REPORT" ">3 s             1  25%"
expect "$REPORT" "10h 4"
expect "$REPORT" "menu.track                             1  25%"
expect "$REPORT" "perf.hitch.stack: 3 (default 2, eventTracking 1)"
expect "$REPORT" "2  worst 1150 ms  [default×1 eventTracking×1]  \$s13PresenterCore12LibraryIndexC7entries2ofSayAA0B5EntryVGAA12DocumentKindO_tKF"
expect "$REPORT" "1  worst 4000 ms  [default×1]  MxU Slides+0x9a3c0"
expect "$REPORT" "perf.pass: 2, sql per pass median 19 max 36"
expect "$REPORT" "eventTracking        1  median 420 ms  worst 420 ms"
expect "$REPORT" "media×12 in 1 pass · theme×1 in 1 pass · presentations×1 in 1 pass"
expect "$REPORT" "library.storm: 1 by kind: media 1 (opens media×10 theme×2)"
expect "$REPORT" "library.slowOpen: 1 by kind: presentations 1"
expect "$REPORT" "menu.track: 4 menus, median up 1.20 s, hitches while up 1"
expect "$REPORT" "never showed a submenu: 3 of 4; submenu after median 640 ms"
expect "$REPORT" "open latency: median 100 ms worst 120 ms (2 of 3 with a click)"
expect "$REPORT" "hovered a submenu item: 2 of 3; hovered but no submenu: 1"
expect "$REPORT" "longest tick gap: median 110 ms worst 350 ms, late ticks 2"
expect "$REPORT" "== 2026-09-24 (13 crumbs)"
expect "$REPORT" "flags: none"
expect "$REPORT" "FLAG cpu >= 90% for 3 pulses in a row (14:02Z-14:04Z), peak 106%"
expect "$REPORT" "FLAG perf.spin: 1 runaway main thread, 133 s in all, longest 133 s"
expect "$REPORT" "1  \$s9MxUSlides14SlideEditorViewV13editorToolbaryQrAA0bC5ModelCF"
expect "$REPORT" "FLAG perf.bodyStorm: 3 by view: AnimationTimelinePanel 2 (worst 31/s), SlideObjectInspector 1 (worst 61/s)"
if [[ "$REPORT" == *"for 1 pulses"* ]]; then failed=$((failed + 1)); echo "FAIL: one hot pulse alone is flagged"; else passed=$((passed + 1)); fi
expect "$SHIFTED" "hitches by hour (UTC-4):"
expect "$SHIFTED" "06h 4"
expect "$EMPTY" "no breadcrumbs-<day>.log found"
if [ "$EMPTY_STATUS" -eq 1 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: empty input exited $EMPTY_STATUS"; fi

echo "hitch-report: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
