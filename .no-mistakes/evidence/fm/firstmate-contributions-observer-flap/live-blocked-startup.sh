#!/usr/bin/env bash
# Live drive: real bin/fm-watch-arm.sh in a disposable lab FM_HOME while a
# separate process holds the wake-queue lock (stand-in for a long fm-wake-drain).
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'touch "$LAB/release"; FM_HOME="$LAB" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1; sleep 1; rm -rf "$LAB"' EXIT
STATE="$LAB/state"
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
 FM_HOME="$LAB" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2/.wake-queue.lock" || exit 1; : > "$3/holding"; while [ ! -e "$3/release" ]; do sleep 0.2; done; fm_lock_release "$2/.wake-queue.lock"' _ "$ROOT" "$STATE" "$LAB" &
HOLDER=$!
while [ ! -e "$LAB/holding" ]; do sleep 0.1; done
echo "== $(date +%T) wake-queue lock held by pid $HOLDER (simulated long drain)"
COMMON="FM_HOME=$LAB FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2"
echo "== $(date +%T) arm A (grace=3s, confirm window=2s, stall bound=60s)"
env -u FM_STATE_OVERRIDE $COMMON "$ROOT/bin/fm-watch-arm.sh" > "$LAB/armA.out" 2>&1 &
A=$!
for i in $(seq 60); do grep -q '^watcher: ' "$LAB/armA.out" && break; sleep 0.1; done
sed 's/^/  armA| /' "$LAB/armA.out"
for t in 2 4 6 8; do sleep 2; echo "  t+${t}s beacon age: $(( $(date +%s) - $(stat -f %m "$STATE/.last-watcher-beat") ))s  lock pid=$(cat "$STATE/.watch.lock/pid") identity=$([ -s "$STATE/.watch.lock/pid-identity" ] && echo present || echo missing)"; done
echo "== $(date +%T) arm B racing, after block > grace + confirm window"
env -u FM_STATE_OVERRIDE $COMMON FM_ARM_ATTACH_POLL=0.1 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/armB.out" 2>&1 &
B=$!
for i in $(seq 60); do grep -q '^watcher: ' "$LAB/armB.out" && break; sleep 0.1; done
sed 's/^/  armB| /' "$LAB/armB.out"
grep -q 'heartbeat is stale' "$LAB/armA.out" "$LAB/armB.out" && echo "RESULT: FAIL stale-heartbeat refusal" || echo "RESULT: no stale-heartbeat refusal"
touch "$LAB/release"; wait $HOLDER
echo "== $(date +%T) lock released; watcher proceeds to its first poll"
sleep 3
echo "  watcher alive: $(kill -0 "$(cat "$STATE/.watch.lock/pid")" 2>/dev/null && echo yes || echo no)  beacon age: $(( $(date +%s) - $(stat -f %m "$STATE/.last-watcher-beat") ))s"
