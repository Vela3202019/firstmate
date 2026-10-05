#!/usr/bin/env bash
# Arm a real watcher on a disposable home and delete its state directory the
# moment the arm reports "started" (a torn-down temporary home), N times.
# Reports whether the watcher exits with the state-gone reason within 40s.
set -u
R=$1; N=${2:-6}
sed '/^test_attached_arm_reports_the_delivered_wake$/,$d' "$R/tests/fm-watch-arm.test.sh" > "$R/tests/.r-arm.sh"
. "$R/tests/.r-arm.sh"; rm -f "$R/tests/.r-arm.sh"
fail() { echo "FAIL: $*"; return 1; }
for k in $(seq "$N"); do
  dir=$(make_case "rm-$k"); home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$home/data"
  start_owned_watcher "$home" "$state" "$fakebin" "$dir/arm.out" || continue
  rm -rf "$state"
  if wait_for_pid_gone "$WATCH_PID" 400; then r="exited"; else
    r="STILL ALIVE after 40s: $(ps -o command= -p $WATCH_PID | cut -c1-80); children: $(pgrep -P $WATCH_PID | xargs -I{} ps -o command= -p {} | tr '\n' ';' | cut -c1-200)"
    kill -TERM "$WATCH_PID" 2>/dev/null; fi
  wait_for_exit "$ARM_PID" 100 >/dev/null 2>&1 || true
  printf 'run %s: watcher %s; arm said: %s\n' "$k" "$r" "$(tr '\n' '|' < "$dir/arm.out")"
done
