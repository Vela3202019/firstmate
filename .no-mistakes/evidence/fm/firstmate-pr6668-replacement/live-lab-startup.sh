#!/usr/bin/env bash
# Live lab: a real fm-watch-arm.sh/fm-watch.sh in a disposable marked lab home.
set -u
ROOT=$1
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
STATE="$LAB/state"
ts() { date +%H:%M:%S; }
echo "[$(ts)] lab home: $LAB"
hold_lock() {  # $1 = flag dir
  bash -c '. "$1"; fm_lock_try_acquire "$2/.wake-queue.lock" || exit 1; : > "$3/holding"
    i=0; while [ $i -lt 900 ] && [ ! -e "$3/release" ]; do sleep 0.1; i=$((i+1)); done
    fm_lock_release "$2/.wake-queue.lock" || true' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$1" &
  HOLDER=$!; while [ ! -e "$1/holding" ]; do sleep 0.1; done
}
echo "=== Scenario A: watcher blocked at startup on the wake-queue lock"
F="$LAB/flagsA"; mkdir -p "$F"; hold_lock "$F"
echo "[$(ts)] wake-queue lock held by pid $HOLDER (simulated long drain)"
FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 \
  "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm1.out" 2>&1 &
ARM1=$!
sleep 3; echo "[$(ts)] first arm output:"; sed 's/^/    /' "$LAB/arm1.out"
sleep 4
echo "[$(ts)] after 7s blocked (guard grace=3s):"
echo "    .watch.lock/pid = $(cat "$STATE/.watch.lock/pid" 2>/dev/null)"
echo "    .watcher-startup-beat = $(cat "$STATE/.watcher-startup-beat" 2>/dev/null) age=$(( $(date +%s) - $(stat -f %m "$STATE/.watcher-startup-beat") ))s"
echo "    .last-watcher-beat exists? $([ -e "$STATE/.last-watcher-beat" ] && echo YES || echo no)"
FM_ARM_ATTACH_POLL=0.1 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 \
  "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm2.out" 2>&1 &
ARM2=$!
sleep 2; echo "[$(ts)] racing arm output:"; sed 's/^/    /' "$LAB/arm2.out"
: > "$F/release"; wait "$HOLDER" 2>/dev/null
sleep 4
echo "[$(ts)] after releasing the lock:"
echo "    .watcher-startup-beat exists? $([ -e "$STATE/.watcher-startup-beat" ] && echo YES || echo no)"
echo "    .last-watcher-beat exists? $([ -e "$STATE/.last-watcher-beat" ] && echo "yes (age $(( $(date +%s) - $(stat -f %m "$STATE/.last-watcher-beat") ))s, real poll)" || echo NO)"
"$ROOT/bin/fm-watch-arm.sh" --stop > "$LAB/stop.out" 2>&1; sed 's/^/    stop: /' "$LAB/stop.out"
wait "$ARM1" "$ARM2" 2>/dev/null
sleep 1
echo "=== Scenario B: startup wedged past the stall bound (3s) goes stale and refuses"
rm -rf "$STATE/.watch.lock" "$STATE/.last-watcher-beat"
F="$LAB/flagsB"; mkdir -p "$F"; hold_lock "$F"
start=$SECONDS
FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_STALL_BOUND=3 \
  "$ROOT/bin/fm-watch.sh" > "$LAB/w.out" 2> "$LAB/w.err" &
W=$!; wait "$W"; rc=$?
echo "[$(ts)] watcher exited rc=$rc after $((SECONDS-start))s; stderr:"; sed 's/^/    /' "$LAB/w.err"
echo "    lock pid retained = $(cat "$STATE/.watch.lock/pid" 2>/dev/null) (watcher was $W)"
echo "    .watcher-startup-beat exists? $([ -e "$STATE/.watcher-startup-beat" ] && echo YES || echo no)"
echo "    .last-watcher-beat exists? $([ -e "$STATE/.last-watcher-beat" ] && echo YES || echo no)"
: > "$F/release"; wait "$HOLDER" 2>/dev/null
pkill -f "$LAB" 2>/dev/null
rm -rf "$LAB"; echo "[$(ts)] lab removed"
