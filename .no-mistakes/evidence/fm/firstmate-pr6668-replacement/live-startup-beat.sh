#!/usr/bin/env bash
# Live: real fm-watch-arm.sh/fm-watch.sh in a disposable lab home; a foreign
# process holds the wake-queue lock so the watcher blocks in its startup
# recovery transitions. Then a racing arm must attach (not refuse as stale).
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
echo "== [t=0] foreign process holds state/.wake-queue.lock"
FM_POLL=1 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 bin/fm-watch-arm.sh > "$LAB/arm1.out" 2>&1 &
sleep 3; echo "== first arm output:"; cat "$LAB/arm1.out"
sleep 4
echo "== [t~7s, past 3s grace] state files:"; ls -la "$STATE" | grep -E 'beat' ; echo "startup-beat names pid: $(cat $STATE/.watcher-startup-beat 2>/dev/null)"; echo "lock pid: $(cat $STATE/.watch.lock/pid)"
echo "== racing arm (FM_GUARD_GRACE=3):"
FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_ATTACH_POLL=0.1 bin/fm-watch-arm.sh > "$LAB/arm2.out" 2>&1 &
A2=$!; sleep 3; cat "$LAB/arm2.out"
echo "== releasing wake-queue lock; watcher should finish startup and poll"
: > "$LAB/release"; sleep 4
ls -la "$STATE" | grep -E 'beat'; [ -e "$STATE/.watcher-startup-beat" ] && echo "startup beat STILL present" || echo "startup beat removed after startup finished"
kill $A2 2>/dev/null
