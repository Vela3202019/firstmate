#!/usr/bin/env bash
# Drive the real bin/fm-watch-arm.sh + bin/fm-watch.sh against a disposable
# home/state while a live process holds the wake-queue lock (as a long
# fm-wake-drain does). Usage: drive-watcher-startup.sh <repo-root>
set -u
R=$1
sed '/^test_rearm_resurfaces_durable_queue_and_remote_open_decision() {/,$d' "$R/tests/fm-watch-arm.test.sh" > "$R/tests/.drive-lib.sh"
. "$R/tests/.drive-lib.sh"; rm -f "$R/tests/.drive-lib.sh"
fail() { echo "FAIL: $*"; }
age() { FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_path_age "$2" 2>/dev/null || echo none' _ "$R/bin/fm-wake-lib.sh" "$1/.last-watcher-beat"; }
hold_queue_lock() { # <dir> <state> <home>
  ( export FM_HOME="$3" FM_STATE_OVERRIDE="$2"; . "$R/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2/.wake-queue.lock" || exit 1; : > "$1/holding"
    i=0; while [ $i -lt 900 ] && [ ! -e "$1/release" ]; do sleep 0.1; i=$((i+1)); done
    fm_lock_release "$2/.wake-queue.lock" || true ) &
  HOLDER=$!; while [ ! -e "$1/holding" ]; do sleep 0.1; done
}

echo "### Scenario A: arm + racing arm against a watcher blocked on the wake-queue lock (grace=3s, confirm=2s)"
dir=$(make_case drive-blocked); home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$home/data"
hold_queue_lock "$dir" "$state" "$home"; echo "holder pid $HOLDER holds $state/.wake-queue.lock"
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 \
  FM_ARM_CONFIRM_TIMEOUT=2 "$R/bin/fm-watch-arm.sh" > "$dir/arm.out" 2>&1 &
ARM=$!
for t in 1 2 3 4 5 6 7 8; do
  sleep 1
  printf 't=%ss beacon-age=%s pid-identity=%s lock-pid=%s\n' "$t" "$(age "$state")" \
    "$([ -s "$state/.watch.lock/pid-identity" ] && echo present || echo missing)" "$(cat "$state/.watch.lock/pid" 2>/dev/null || echo -)"
done
echo "--- first arm output:"; cat "$dir/arm.out"
echo "--- racing arm (wake-queue lock still held: $([ -e "$dir/release" ] && echo no || echo yes)):"
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
  FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 "$R/bin/fm-watch-arm.sh" > "$dir/race.out" 2>&1 &
RACE=$!; i=0
while [ $i -lt 60 ] && is_live_non_zombie $RACE && ! grep -q 'watcher:' "$dir/race.out"; do sleep 0.1; i=$((i+1)); done
sleep 0.5; cat "$dir/race.out"
: > "$dir/release"; wait $HOLDER 2>/dev/null
echo "--- released wake-queue lock; beacon ages after release:"
for t in 1 2 3; do sleep 1; echo "beacon-age=$(age "$state")"; done
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$R/bin/fm-watch-arm.sh" --stop 2>&1 | head -3
kill $RACE $ARM 2>/dev/null; wait 2>/dev/null

echo; echo "### Scenario B: startup wedged past the stall bound (FM_WATCHER_STALL_BOUND=3) goes stale and refuses"
dir=$(make_case drive-wedged); home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$home/data"
hold_queue_lock "$dir" "$state" "$home"
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_STALL_BOUND=3 "$R/bin/fm-watch.sh" > "$dir/w.out" 2> "$dir/w.err" &
W=$!; i=0; while [ $i -lt 150 ] && is_live_non_zombie $W; do sleep 0.1; i=$((i+1)); done
if is_live_non_zombie $W; then echo "watcher pid $W still running after 15s (no refusal)"; kill $W; else wait $W; echo "watcher exit=$?"; fi
echo "stderr: $(cat "$dir/w.err")"
echo "lock pid retained: $(cat "$state/.watch.lock/pid" 2>/dev/null || echo -) (watcher was $W)"
a1=$(age "$state"); sleep 2; a2=$(age "$state"); echo "beacon-age $a1 -> $a2 (2s later)"
: > "$dir/release"; wait $HOLDER 2>/dev/null
