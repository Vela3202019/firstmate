#!/usr/bin/env bash
# Live drive: (1) watcher wedged behind a hung wake-queue holder past the stall
# bound stops beating and refuses; (2) state dir deleted right after the arm
# reports started (while startup is blocked) -> watcher exits with state-gone reason.
set -u
ROOT=$1
age() { echo $(( $(date +%s) - $(stat -f %m "$1") )); }
hold() {  # <lab>
  FM_HOME="$1" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2/state/.wake-queue.lock" || exit 1; : > "$2/holding"; while [ ! -e "$2/release" ] && [ -d "$2/state" ]; do sleep 0.2; done; fm_lock_release "$2/state/.wake-queue.lock" 2>/dev/null' _ "$ROOT" "$1" &
  while [ ! -e "$1/holding" ]; do sleep 0.1; done
}
E="env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE"
echo "### Scenario: startup wedged past the stall bound (bound=4s, hung holder never releases)"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
hold "$LAB"
$E FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_STALL_BOUND=4 "$ROOT/bin/fm-watch.sh" > "$LAB/w.out" 2> "$LAB/w.err" &
W=$!; s=$(date +%s)
while kill -0 $W 2>/dev/null; do sleep 0.2; done; wait $W; rc=$?
echo "  watcher exited rc=$rc after $(( $(date +%s) - s ))s; stderr: $(cat "$LAB/w.err")"
echo "  lock evidence retained: pid file names $(cat "$LAB/state/.watch.lock/pid") (watcher was $W)"
a1=$(age "$LAB/state/.last-watcher-beat"); sleep 3; a2=$(age "$LAB/state/.last-watcher-beat")
echo "  beacon age after refusal: ${a1}s -> ${a2}s (still aging = not faking supervision)"
touch "$LAB/release"; sleep 0.5; rm -rf "$LAB"
echo
echo "### Scenario: state dir removed right after 'watcher: started' (x6)"
for n in 1 2 3 4 5 6; do
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  hold "$LAB"
  $E FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=5 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
  A=$!
  for i in $(seq 100); do grep -q '^watcher: ' "$LAB/arm.out" && break; sleep 0.1; done
  W=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$LAB/arm.out")
  rm -rf "$LAB/state"; s=$(date +%s)
  for i in $(seq 150); do kill -0 "$W" 2>/dev/null || break; sleep 0.1; done
  alive=$(kill -0 "$W" 2>/dev/null && echo STILL-ALIVE || echo exited)
  for i in $(seq 100); do kill -0 $A 2>/dev/null || break; sleep 0.1; done
  echo "  run $n: arm said '$(head -1 "$LAB/arm.out")'; watcher $W $alive within $(( $(date +%s) - s ))s; reason: $(grep -o 'watcher: exiting[^/]*\|watcher: [a-z].*failed\|recovery state[^;]*' "$LAB/arm.out" | head -1)"
  [ "$alive" = STILL-ALIVE ] && kill "$W"
  touch "$LAB/release" 2>/dev/null; rm -rf "$LAB"
done
