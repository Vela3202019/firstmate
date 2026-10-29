#!/usr/bin/env bash
# Live: real fm-watch-arm.sh in a disposable lab home; the wake-queue lock is
# held by a hung foreign holder past FM_WATCHER_STALL_BOUND=4. The watcher must
# stop its startup beat, refuse with stale lock evidence, and a later arm must
# not attach to it as healthy.
set -u
ROOT=$PWD
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export FM_HOME="$LAB" TMUX_TMPDIR="$TD"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
tmux new-session -d -s primary -c "$ROOT" bash
STATE="$LAB/state"
cleanup() { : > "$LAB/release"; sleep 1; bin/fm-watch-arm.sh --stop >/dev/null 2>&1; tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
bash -c '. "$1"; fm_lock_try_acquire "$2/.wake-queue.lock" || exit 1; : > "$3/holding"; i=0
  while [ $i -lt 900 ] && [ ! -e "$3/release" ]; do sleep 0.1; i=$((i+1)); done
  fm_lock_release "$2/.wake-queue.lock"' _ bin/fm-wake-lib.sh "$STATE" "$LAB" &
while [ ! -e "$LAB/holding" ]; do sleep 0.1; done
echo "== [t=0] hung foreign holder owns state/.wake-queue.lock; starting watcher with FM_WATCHER_STALL_BOUND=4"
start=$SECONDS
FM_POLL=1 FM_SIGNAL_GRACE=0 FM_WATCHER_STALL_BOUND=4 bin/fm-watch.sh > "$LAB/w.out" 2> "$LAB/w.err" &
W=$!
sleep 2; echo "[t=2s] startup beat: $(cat $STATE/.watcher-startup-beat 2>/dev/null || echo absent) (watcher pid $W)"
wait $W; rc=$?
echo "== watcher exited rc=$rc after $((SECONDS-start))s; stderr:"; cat "$LAB/w.err"
echo "lock pid retained: $(cat $STATE/.watch.lock/pid 2>/dev/null || echo none)"
echo "startup beat after refusal: $([ -e $STATE/.watcher-startup-beat ] && echo PRESENT || echo absent)"
echo "poll beat (.last-watcher-beat): $([ -e $STATE/.last-watcher-beat ] && echo PRESENT || echo absent)"
. bin/fm-wake-lib.sh
echo "fm_watcher_healthy now: $(fm_watcher_healthy "$STATE" "$ROOT/bin/fm-watch.sh" 3 && echo healthy || echo NOT-healthy)"
