#!/usr/bin/env bash
# Live drive: real bin/fm-watch-arm.sh + bin/fm-watch.sh against a disposable lab home.
set -u
ROOT=$1
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMUXD"; unset TMUX
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
S="$LAB/state"
say() { printf '\n### %s\n' "$*"; }
hold_lock() { # $1 = flag dir
  bash -c '. "$1"; fm_lock_try_acquire "$2/.wake-queue.lock" || exit 1; : > "$3/holding"
    i=0; while [ $i -lt 900 ] && [ ! -e "$3/release" ]; do sleep 0.1; i=$((i+1)); done
    fm_lock_release "$2/.wake-queue.lock" || true' _ "$ROOT/bin/fm-wake-lib.sh" "$S" "$1" &
  HOLDER=$!; for _ in $(seq 50); do [ -e "$1/holding" ] && break; sleep 0.1; done
}
F=$(mktemp -d "${TMPDIR:-/tmp}/fm-labflag.XXXXXX")

say "Scenario A: arm a watcher while a long drain holds the wake-queue lock"
hold_lock "$F"; echo "wake-queue lock held by pid $HOLDER"
FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=3 \
  FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 "$ROOT/bin/fm-watch-arm.sh" > "$F/arm1.out" 2>&1 &
ARM1=$!
for _ in $(seq 80); do grep -q '^watcher: started pid=' "$F/arm1.out" && break; sleep 0.1; done
echo "first arm output:"; cat "$F/arm1.out"
WPID=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$F/arm1.out" | head -1)
sleep 6
echo "after 6s (> 3s grace) still blocked at startup:"
echo "  startup beacon contents: $(cat "$S/.watcher-startup-beat" 2>/dev/null || echo MISSING)  age: $(( $(date +%s) - $(stat -f %m "$S/.watcher-startup-beat") ))s"
echo "  poll beacon .last-watcher-beat exists? $([ -e "$S/.last-watcher-beat" ] && echo YES || echo no)"
echo "  fm_watcher_beat_age for pid $WPID: $(bash -c '. "$1"; fm_watcher_beat_age "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$S" "$WPID")"
say "Scenario B: a racing second arm attaches (not 'stale') and reports the real startup beacon age"
FM_ARM_ATTACH_POLL=0.1 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 \
  "$ROOT/bin/fm-watch-arm.sh" > "$F/arm2.out" 2>&1 &
ARM2=$!
for _ in $(seq 80); do grep -q 'watcher: attached' "$F/arm2.out" && break; sleep 0.1; done
cat "$F/arm2.out"
say "Scenario C: stop the watcher (TERM) while it is still in its startup wait"
KIDS=$(pgrep -P "$WPID" | tr '\n' ' '); echo "watcher children before TERM (incl. startup beat helper): $KIDS"
kill -TERM "$WPID"
for _ in $(seq 100); do kill -0 "$WPID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$WPID" 2>/dev/null && echo "watcher STILL ALIVE" || echo "watcher $WPID exited"
sleep 2
for k in $KIDS; do echo "  child $k alive after stop? $(kill -0 "$k" 2>/dev/null && echo YES || echo no)"; done
echo "startup beacon after stop: $([ -e "$S/.watcher-startup-beat" ] && echo "STILL PRESENT ($(cat "$S/.watcher-startup-beat"))" || echo removed)"
: > "$F/release"; wait "$HOLDER" 2>/dev/null
kill "$ARM1" "$ARM2" 2>/dev/null; wait 2>/dev/null
"$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true

say "Scenario D: a startup wedged behind a hung holder goes stale at the stall bound and refuses"
rm -rf "$F"; F=$(mktemp -d "${TMPDIR:-/tmp}/fm-labflag.XXXXXX")
hold_lock "$F"
T0=$(date +%s)
FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=3 \
  FM_WATCHER_STALL_BOUND=4 FM_ARM_CONFIRM_TIMEOUT=2 "$ROOT/bin/fm-watch-arm.sh" > "$F/arm3.out" 2>&1 &
ARM3=$!
for _ in $(seq 80); do grep -q '^watcher: started pid=' "$F/arm3.out" && break; sleep 0.1; done
W3=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$F/arm3.out" | head -1)
echo "watcher pid=$W3 started; waiting for it to give up"
for _ in $(seq 300); do kill -0 "$W3" 2>/dev/null || break; sleep 0.1; done
echo "watcher alive after $(( $(date +%s) - T0 ))s? $(kill -0 "$W3" 2>/dev/null && echo YES || echo no)"
echo "startup beacon: $([ -e "$S/.watcher-startup-beat" ] && echo present || echo removed);  poll beacon .last-watcher-beat: $([ -e "$S/.last-watcher-beat" ] && echo present || echo absent)"
echo "watcher log tail:"; tail -n 5 "$S"/watch*.log 2>/dev/null | grep -i 'recovery state\|stale' ; grep -rh 'recovery state could not' "$S" "$F" 2>/dev/null | head -3
echo "fm_watcher_beat_age for $W3: $(bash -c '. "$1"; fm_watcher_beat_age "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$S" "$W3")"
: > "$F/release"; wait "$HOLDER" 2>/dev/null
kill "$ARM3" 2>/dev/null; wait 2>/dev/null
"$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
rm -rf "$F"; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"
echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
