#!/bin/zsh
set -u
setopt pipefail nonomatch

HERE=${0:A:h}
MAC=${HERE:h:h}
REPO=$(git -C "$MAC" rev-parse --show-toplevel)
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
REAL="/Applications/MxU Slides.app"
IDENTITY=${MXU_PERF_IDENTITY:--}
PORT=6989
DOMAIN=com.example.mxuslides.perf
IDLE_SECONDS=${MXU_PERF_IDLE_SECONDS:-10}
export PATH="$HOME/.asdf/shims:/opt/homebrew/bin:$PATH"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if (( $# < 1 || $# > 2 )); then
  print -r -- "usage: scripts/perf/run.sh <commit | path/to/MxU Slides.app> [baseline.json]" >&2
  exit 2
fi
TARGET=$1
BASELINE=${2:-$HERE/baseline.json}
mkdir -p "$WORK"/{Stage,homes,runs}

log() { print -r -- "==> $*" }
APP_PID=""
REAL_WAS_RUNNING=0

cleanup() {
  if [[ -n $APP_PID ]] && kill -0 $APP_PID 2>/dev/null; then
    kill -TERM $APP_PID 2>/dev/null
    for _ in {1..50}; do kill -0 $APP_PID 2>/dev/null || break; sleep 0.1; done
    kill -KILL $APP_PID 2>/dev/null
  fi
  APP_PID=""
  defaults delete $DOMAIN >/dev/null 2>&1
  if (( REAL_WAS_RUNNING )) && ! pgrep -f "$REAL/Contents/MacOS/MxU Slides" >/dev/null; then
    log "reopening $REAL in the background"
    open -g "$REAL"
    REAL_WAS_RUNNING=0
  fi
}
die() { print -r -- "run.sh: $*" >&2; cleanup; exit 1 }
trap 'die "interrupted"' INT TERM

if [[ -d $TARGET && $TARGET == *.app ]]; then
  LABEL=${MXU_PERF_LABEL:-"${${TARGET:t}:r:gs/ /-/}"}
  COMMIT=$(/usr/libexec/PlistBuddy -c 'Print MXUGitCommit' "$TARGET/Contents/Info.plist" 2>/dev/null || print "?")
  BUILT=$TARGET
else
  COMMIT=$(git -C "$REPO" rev-parse --verify --short=10 "$TARGET^{commit}") || die "no commit $TARGET"
  LABEL=$COMMIT
  SRC=$WORK/src
  if [[ ! -d $SRC ]]; then
    git -C "$REPO" worktree add --detach "$SRC" "$COMMIT" >/dev/null 2>&1 || die "could not add a worktree at $SRC"
  fi
  git -C "$SRC" checkout -q --detach "$COMMIT" || die "could not check out $COMMIT in $SRC"
  SMAC=$SRC/apps/mac
  log "building $COMMIT (Release, arm64, MXU_PERF_HOOKS)"
  xcodegen generate --spec "$SMAC/project.yml" --project "$SMAC" >/dev/null || die "xcodegen failed"
  xcodebuild -project "$SMAC/MxUSlides.xcodeproj" -scheme MxUSlides -configuration Release \
    -derivedDataPath "$WORK/dd" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MXU_PERF_HOOKS' MXU_GIT_COMMIT="$COMMIT" \
    build > "$WORK/build-$COMMIT.log" 2>&1 || die "build failed: $WORK/build-$COMMIT.log"
  BUILT="$WORK/dd/Build/Products/Release/MxU Slides.app"
fi

APP="$WORK/Stage/$LABEL.app"
log "staging $APP (Developer ID, release entitlements)"
codesign -d --entitlements - --xml "$REAL" > "$WORK/release.entitlements" 2>/dev/null \
  || die "cannot read the release entitlements from $REAL"
if [[ ${BUILT:A} != ${APP:A} ]]; then
  rm -rf "$APP" && ditto "$BUILT" "$APP" || die "cannot stage $BUILT"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOMAIN" "$APP/Contents/Info.plist" \
  || die "cannot give the staged build its own bundle identifier"
codesign --force --deep --entitlements "$WORK/release.entitlements" --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
  || die "re-signing with $IDENTITY failed"
BIN="$APP/Contents/MacOS/MxU Slides"
if [[ -n ${MXU_PERF_BUILD_ONLY:-} ]]; then
  log "built and staged: $APP (MXU_PERF_BUILD_ONLY: not measuring)"
  exit 0
fi
[[ -f $WORK/drag60 && $WORK/drag60 -nt $HERE/drag60.swift ]] || xcrun swiftc -O -o "$WORK/drag60" "$HERE/drag60.swift" \
  || die "cannot build drag60"

if pgrep -f "Stage/.*\.app/Contents/MacOS/MxU Slides" >/dev/null; then
  die "another staged MxU Slides is running (another session's perf run?): not starting a second"
fi
if pgrep -f "$REAL/Contents/MacOS/MxU Slides" >/dev/null; then
  log "quitting $REAL (reopened in the background at the end)"
  REAL_WAS_RUNNING=1
  osascript -e 'tell application id "com.example.mxuslides" to quit' >/dev/null 2>&1
  for _ in {1..100}; do pgrep -f "$REAL/Contents/MacOS/MxU Slides" >/dev/null || break; sleep 0.2; done
  pgrep -f "$REAL/Contents/MacOS/MxU Slides" >/dev/null && die "$REAL did not quit"
fi

HOME_DIR=""
support() { print -r -- "$HOME_DIR/Library/Application Support/MxU Slides" }

launch() {
  HOME_DIR=$1
  CFFIXED_USER_HOME=$1 MXU_SKIP_KEYCHAIN=1 MXU_PERF_SCENARIO=$2 \
    sandbox-exec -f "$HERE/nonet.sb" "$BIN" > "$RUN/app-${2%%:*}.log" 2>&1 &
  APP_PID=$!
}

quit_app() {
  [[ -n $APP_PID ]] || return
  kill -TERM $APP_PID 2>/dev/null
  for _ in {1..100}; do kill -0 $APP_PID 2>/dev/null || break; sleep 0.1; done
  kill -KILL $APP_PID 2>/dev/null
  APP_PID=""
}

crumb() {
  local line
  for _ in {1..$(( ${2:-90} * 10 ))}; do
    line=$(cat "$(support)"/Diagnostics/breadcrumbs-*.log 2>/dev/null | grep -E " (perf\.scenario\.failed|$1) — " | tail -1)
    [[ -n $line ]] && { print -r -- "$line"; return 0 }
    kill -0 $APP_PID 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

READY=""
await_ready() {
  local line
  line=$(crumb "perf\.scenario\.ready" 120)
  [[ $line == *"perf.scenario.ready"* ]] && { READY=$line; return }
  if [[ -z $(cat "$(support)"/Diagnostics/breadcrumbs-*.log 2>/dev/null | grep " perf\.scenario — ") ]]; then
    die "$1: this build has no perf hooks (build it with MXU_PERF_HOOKS, as run.sh <commit> does)"
  fi
  die "$1: ${line:-no perf.scenario.ready in 120 s} (app log: $RUN)"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ }
signal() { notifyutil -p "com.example.mxuslides.perf.$1" }

step() { print -r -- "$1" >> "$RUN/steps.jsonl" }

KEY=$(cat "$HERE"/fixtures/*.json "$HERE/make-library.py" | shasum | cut -c1-10)
LIB=$WORK/library-$KEY
RUN=$WORK/runs/$LABEL-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN"

reset_prefs() { defaults delete $DOMAIN >/dev/null 2>&1; true }

prefs() {
  reset_prefs
  defaults write $DOMAIN localAPI.enabled -bool YES
  defaults write $DOMAIN localAPI.port -int $PORT
  defaults write $DOMAIN localAPI.defaultKeyOffered -bool YES
}

if [[ ! -f $LIB/ready ]]; then
  log "building the 302-deck library through the sandbox's Local API (once)"
  rm -rf "$LIB" && mkdir -p "$LIB"
  local_home=$LIB/home
  library="$local_home/Library/Application Support/MxU Slides/Library"
  mkdir -p "$library" && touch "$library/.onboarded-v1"
  prefs
  SECRET=$(python3 "$HERE/make-library.py" mint "$library/local-api-tokens.json") || die "cannot mint a token"
  launch "$local_home" idle
  await_ready "building the library"
  for _ in {1..100}; do
    curl -sf -o /dev/null -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$PORT/v1/documents/presentations" && break
    sleep 0.2
  done
  python3 "$HERE/make-library.py" build --port $PORT --token "$SECRET" --fixtures "$HERE/fixtures" \
    || die "building the library failed"
  sleep 3
  quit_app
  touch "$LIB/ready"
fi

FRESH=""
fresh_home() {
  reset_prefs
  FRESH=$WORK/homes/$1
  rm -rf "$FRESH" && cp -cR "$LIB/home" "$FRESH" || die "cannot clone the library"
  rm -rf "$FRESH/Library/Application Support/MxU Slides/Diagnostics"
}

await_quiet() {
  local waited=0
  while (( $(sysctl -n vm.loadavg | awk '{print int($2)}') >= 3 )); do
    (( waited == 0 )) && log "waiting for the Mac to go quiet (load $(sysctl -n vm.loadavg | awk '{print $2}'))"
    (( waited++ > 60 )) && { log "still busy after 10 min: measuring anyway (numbers may be high)"; return }
    sleep 10
  done
}

hid_idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' }

await_idle() {
  local waited=0
  while (( $(hid_idle) < IDLE_SECONDS )); do
    (( waited == 0 )) && log "waiting until the Mac has been idle ${IDLE_SECONDS}s before synthetic input"
    (( waited++ > 900 )) && die "the Mac never went idle; nothing was dragged"
    sleep 1
  done
}

front() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1
  sleep 0.5
  local pid
  pid=$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)
  [[ $pid == $APP_PID ]]
}

targets() {
  local before line
  before=$(cat "$(support)"/Diagnostics/breadcrumbs-*.log 2>/dev/null | grep -c " perf\.targets — ")
  signal targets
  for _ in {1..50}; do
    line=$(cat "$(support)"/Diagnostics/breadcrumbs-*.log 2>/dev/null | grep " perf\.targets — " | tail -1)
    (( $(cat "$(support)"/Diagnostics/breadcrumbs-*.log 2>/dev/null | grep -c " perf\.targets — ") > before )) && break
    sleep 0.1
  done
  print -r -- "$line" | sed -nE "s/.*$1 ([0-9-]+),([0-9-]+).*/\1 \2/p"
}

drag() {
  await_idle
  front || die "the staged MxU Slides is not in front: no synthetic input"
  (( $(hid_idle) >= 1 )) || die "input arrived while fronting the app: stopping"
  local x y
  read -r x y <<< "$(targets $3)"
  [[ -n $x && -n $y ]] || die "the app reported no $3 point for the card"
  signal mark
  local from=$(now)
  sample $APP_PID 4 1 -mayDie -file "$RUN/$1-$2.txt" >/dev/null 2>&1 &
  local sampler=$!
  sleep 0.3
  "$WORK/drag60" $x $y $4 $5 $6 60 1 >/dev/null
  wait $sampler
  local to=$(now)
  signal mark
  sleep 1.2
  step "{\"step\": \"$1\", \"n\": $2, \"sample\": \"$1-$2.txt\", \"from\": \"$from\", \"to\": \"$to\", \"diagnostics\": \"diagnostics-edit\", \"seconds\": 4}"
}

step "{\"step\": \"run\", \"label\": \"$LABEL\", \"commit\": \"$COMMIT\", \"machine\": \"$(sysctl -n machdep.cpu.brand_string)\", \"os\": \"$(sw_vers -productVersion)\", \"date\": \"$(now)\", \"library\": \"302 decks\"}"

log "(a) Themes › Editorial Serif › Lower Third › Animate, idle"
await_quiet
fresh_home animate
launch "$FRESH" "animate:Editorial Serif/Lower Third"
await_ready "the animate scenario"
sleep 6
sample $APP_PID 5 1 -mayDie -file "$RUN/animate-idle.txt" >/dev/null 2>&1
step '{"step": "animateIdle", "sample": "animate-idle.txt"}'

log "(b) playback: two whole preview loops"
signal play
play=$(crumb "perf\.play" 10)
seconds=$(print -r -- "$play" | sed -nE 's/.*— ([0-9.]+) s on repeat.*/\1/p' | awk '{s=int($1*2+0.99); print (s<3?3:(s>10?10:s))}')
seconds=${seconds:-3}
sleep 1
signal mark
from=$(now)
sample $APP_PID $seconds 1 -mayDie -file "$RUN/playback.txt" >/dev/null 2>&1
to=$(now)
signal mark
sleep 1.2
signal stop
step "{\"step\": \"playback\", \"sample\": \"playback.txt\", \"from\": \"$from\", \"to\": \"$to\", \"diagnostics\": \"diagnostics-animate\", \"seconds\": $seconds}"
quit_app
cp -R "$(support)/Diagnostics" "$RUN/diagnostics-animate"

log "(e) render thread, \"Path Text Perf\" slide 1 on screen"
await_quiet
fresh_home edit
launch "$FRESH" "edit:Path Text Perf/1/Card"
await_ready "the edit scenario"
[[ $READY == *"center "[0-9]* ]] || die "the edit scenario found no card on screen: $READY"
sleep 6
sample $APP_PID 5 1 -mayDie -file "$RUN/render.txt" >/dev/null 2>&1
step '{"step": "render", "sample": "render.txt"}'

log "(c) three one-way 60 Hz drags of the card"
drag drag 1 center 200 60 100
drag drag 2 center -200 -60 100
drag drag 3 center 200 60 100

log "(d) two resizes from the bottom-right handle"
drag resize 1 handle -120 -80 60
drag resize 2 handle 120 80 60
quit_app
cp -R "$(support)/Diagnostics" "$RUN/diagnostics-edit"

cleanup
trap - INT TERM
python3 "$HERE/analyze.py" "$RUN" "$BASELINE"
