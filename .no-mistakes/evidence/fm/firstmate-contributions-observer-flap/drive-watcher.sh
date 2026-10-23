#!/usr/bin/env bash
# Live driver: real bin/fm-watch-arm.sh / bin/fm-watch.sh against a disposable marked lab home.
# Usage: drive-watcher.sh <scenario>   (blocked | wedged | stategone)
set -u
ROOT=/Users/vela/.no-mistakes/worktrees/34bae1aacd62/01M5MXY3YHDGWA20J941SW5GNM
SCEN=$1
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
STATE="$LAB/state"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux"
log() { printf '[%s +%ss] %s\n' "$SCEN" "$SECONDS" "$*"; }
age() { echo $(( $(date +%s) - $(stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null || echo 0) )); }
cleanup() {
  : > "$LAB/release"
  "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  for p in $(cat "$STATE/.watch.lock/pid" 2>/dev/null) ${HOLDER:-} ${ARM:-} ${RACE:-} ${W:-}; do kill "$p" 2>/dev/null; done
  sleep 1
  tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
  log "lab removed: $LAB"
}
trap cleanup EXIT
log "lab home: $LAB"
# A live holder on the wake-queue lock (stands in for a long fm-wake-drain run).
( . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.wake-queue.lock" || exit 1
  : > "$LAB/holding"
  while [ ! -e "$LAB/release" ]; do sleep 0.2; done
  fm_lock_release "$STATE/.wake-queue.lock" ) &
HOLDER=$!
while [ ! -e "$LAB/holding" ]; do sleep 0.1; done
log "wake-queue lock held by pid $HOLDER"

case "$SCEN" in
blocked)
  FM_POLL=1 FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 \
    "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
  ARM=$!
  for _ in $(seq 100); do grep -q '^watcher:' "$LAB/arm.out" && break; sleep 0.1; done
  log "arm A output: $(head -1 "$LAB/arm.out")"
  W=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$LAB/arm.out" | head -1)
  log "lock pid=$(cat $STATE/.watch.lock/pid 2>/dev/null) pid-identity present=$([ -s $STATE/.watch.lock/pid-identity ] && echo yes || echo no) beacon age=$(age)s"
  sleep 8
  log "after 8s more blocked (grace=3s, confirm=2s): watcher alive=$(kill -0 "$W" 2>/dev/null && echo yes || echo no) beacon age=$(age)s holder still holding=$([ -e $LAB/release ] && echo no || echo yes)"
  FM_GUARD_GRACE=3 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_ATTACH_POLL=0.1 \
    "$ROOT/bin/fm-watch-arm.sh" > "$LAB/race.out" 2>&1 &
  RACE=$!
  for _ in $(seq 100); do grep -q '^watcher:' "$LAB/race.out" && break; sleep 0.1; done
  log "racing arm B output: $(head -3 "$LAB/race.out")"
  grep -q 'heartbeat is stale' "$LAB/race.out" && log "RESULT: FAIL stale-heartbeat refusal" || log "no stale-heartbeat refusal"
  : > "$LAB/release"
  log "released wake-queue lock"
  sleep 4
  log "watcher alive after release=$(kill -0 "$W" 2>/dev/null && echo yes || echo no) beacon age=$(age)s"
  ;;
wedged)
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_STALL_BOUND=4 \
    "$ROOT/bin/fm-watch.sh" > "$LAB/w.out" 2> "$LAB/w.err" &
  W=$!
  sleep 2
  log "watcher pid=$W blocked; beacon age=$(age)s lock pid=$(cat $STATE/.watch.lock/pid)"
  t0=$SECONDS; while kill -0 "$W" 2>/dev/null && [ $((SECONDS-t0)) -lt 20 ]; do sleep 0.2; done
  wait "$W"; rc=$?
  log "watcher exited rc=$rc after ~$((SECONDS-t0+2))s; stderr: $(cat "$LAB/w.err")"
  log "lock evidence retained: pid file=$(cat $STATE/.watch.lock/pid 2>/dev/null)"
  a1=$(age); sleep 3; a2=$(age)
  log "beacon age ${a1}s -> ${a2}s (keeps growing = stale, no helper still beating)"
  : > "$LAB/release"; sleep 1
  FM_POLL=1 FM_GUARD_GRACE=3 FM_ARM_CONFIRM_TIMEOUT=10 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/rearm.out" 2>&1 &
  ARM=$!
  for _ in $(seq 150); do grep -q '^watcher:' "$LAB/rearm.out" && break; sleep 0.1; done
  log "later arm (grace 3s) after hung holder released: $(grep '^watcher:' "$LAB/rearm.out" | head -2)"
  ;;
stategone)
  FM_POLL=1 FM_ARM_CONFIRM_TIMEOUT=5 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
  ARM=$!
  for _ in $(seq 100); do grep -q '^watcher:' "$LAB/arm.out" && break; sleep 0.1; done
  log "arm output: $(head -1 "$LAB/arm.out")"
  W=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$LAB/arm.out" | head -1)
  sleep 1
  rm -rf "$STATE"
  kill "$HOLDER" 2>/dev/null
  log "state directory removed while watcher $W blocked at startup"
  t0=$SECONDS; while kill -0 "$W" 2>/dev/null && [ $((SECONDS-t0)) -lt 30 ]; do sleep 0.2; done
  log "watcher alive after $((SECONDS-t0))s: $(kill -0 "$W" 2>/dev/null && echo yes || echo no)"
  ls "$LAB"/state 2>/dev/null >/dev/null; 
  log "watcher log lines: $(grep -h 'watcher: exiting\|watcher:' "$LAB"/arm.out | tail -3)"
  ;;
esac
