#!/usr/bin/env bash
# Live drive: a real watcher blocked at startup on the wake-queue lock, then its
# state dir is deleted. Expect a prompt exit with the state-gone reason.
set -u
ROOT=$1; DEFAULT_BOUND=${2:-900}
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$D" >/dev/null; home=$D; state=$D/state
( export FM_HOME="$home" FM_STATE_OVERRIDE="$state"; . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$state/.wake-queue.lock" || exit 1; : > "$D/holding"
  i=0; while [ $i -lt 900 ] && [ ! -e "$D/release" ]; do sleep 0.1; i=$((i+1)); done ) &
holder=$!
while [ ! -e "$D/holding" ]; do sleep 0.1; done
echo "[drive] wake-queue lock held by pid $holder; arming watcher (stall bound ${DEFAULT_BOUND}s)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_STALL_BOUND=$DEFAULT_BOUND \
  "$ROOT/bin/fm-watch-arm.sh" > "$D/arm.out" 2>&1 &
arm=$!
for i in $(seq 1 100); do grep -q '^watcher: started pid=' "$D/arm.out" && break; sleep 0.1; done
wp=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$D/arm.out" | head -1)
echo "[drive] arm output so far:"; sed 's/^/  | /' "$D/arm.out"
sleep 2
echo "[drive] beacon age before teardown: $(( $(date +%s) - $(stat -f %m "$state/.last-watcher-beat") ))s; watcher alive: $(kill -0 "$wp" 2>/dev/null && echo yes || echo no)"
t0=$(date +%s); rm -rf "$state"; echo "[drive] removed state dir at t=0"
gone=no; for i in $(seq 1 300); do kill -0 "$wp" 2>/dev/null || { gone=yes; break; }; sleep 0.1; done
echo "[drive] watcher pid $wp exited: $gone after $(( $(date +%s) - t0 ))s"
: > "$D/release"; wait "$holder" 2>/dev/null; wait "$arm" 2>/dev/null
echo "[drive] final arm output:"; sed 's/^/  | /' "$D/arm.out"
kill "$wp" 2>/dev/null; rm -rf "$D"
