#!/usr/bin/env bash
# Live scenario: a real fm-watch-arm.sh owner arm + real fm-watch.sh watcher in a
# disposable lab FM_HOME, watching a real crew pane on a private tmux socket
# (fm-lab). A PATH wrapper delegates every tmux call to that socket and only
# delays capture-pane by CAPTURE_DELAY seconds. Main acknowledges, then a
# --take-over arm takes the cycle over mid-capture.
# Usage: live-takeover-scenario.sh <repo-bin-dir> <capture-delay> <label>
set -u
BIN=$1 DELAY=$2 LABEL=$3
WT=/Users/vela/.no-mistakes/worktrees/34bae1aacd62/01M49PKABF74NX0T7K3KJK59CB
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/shim"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
REAL=/opt/homebrew/bin/tmux
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then touch "$LAB/capture-started"; sleep $DELAY; fi
exec $REAL -L fm-lab "\$@"
SH
chmod +x "$LAB/shim/tmux"
$REAL -L fm-lab new-session -d -s fmlab -n crew 'printf "crew idle prompt\n"; exec cat'
printf 'window=fmlab:crew\nkind=ship\nharness=claude\n' > "$LAB/state/crew.meta"
E="env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH=$LAB/shim:$PATH FM_HOME=$LAB FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 ${EXTRA_ENV:-}"
echo "== [$LABEL] capture delay ${DELAY}s, lab=$LAB"
$E FM_ARM_CONFIRM_TIMEOUT=30 "$BIN/fm-watch-arm.sh" --restart > "$LAB/owner.out" 2>&1 &
OWNER=$!
for _ in $(seq 600); do grep -q '^watcher: started' "$LAB/owner.out" && break; sleep 0.05; done
echo "-- owner arm: $(cat "$LAB/owner.out")"
W=$(cat "$LAB/state/.watch.lock/pid")
for _ in $(seq 400); do [ -e "$LAB/capture-started" ] && break; sleep 0.05; done
echo "-- watcher pid=$W entered its slow pane capture: $([ -e "$LAB/capture-started" ] && echo yes || echo no)"
# Main handles a wake and acknowledges it, exactly as the primary does.
$E bash -c '. "$1"; fm_wake_append signal take-over "signal: handled by main"' _ "$BIN/fm-wake-lib.sh"
$E "$BIN/fm-wake-drain.sh" >/dev/null 2>"$LAB/drain.err"
ACK=$(sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through .*\)$/\1/p' "$LAB/drain.err")
# shellcheck disable=SC2086
$E "$BIN/fm-wake-drain.sh" $ACK >/dev/null 2>&1
echo "-- after main's ack: .watcher-down=$(cat "$LAB/state/.watcher-down")  queue_bytes=$(wc -c < "$LAB/state/.wake-queue" | tr -d ' ')"
T0=$SECONDS
$E FM_ARM_CONFIRM_TIMEOUT=3 "$BIN/fm-watch-arm.sh" --take-over "$OWNER" > "$LAB/takeover.out" 2>&1 &
ARM=$!
for _ in $(seq 1800); do grep -q '^watcher:' "$LAB/takeover.out" && break; kill -0 $ARM 2>/dev/null || break; sleep 0.05; done
echo "-- take-over arm output after $((SECONDS-T0))s:"; sed 's/^/     /' "$LAB/takeover.out"
echo "-- old watcher pid=$W alive: $(kill -0 "$W" 2>/dev/null && echo yes || echo no)"
echo "-- .watcher-down now: $(cat "$LAB/state/.watcher-down" 2>/dev/null)"
for _ in $(seq 600); do kill -0 "$W" 2>/dev/null || break; sleep 0.1; done
sleep 4
echo "-- after the old watcher died: .watcher-down=$(cat "$LAB/state/.watcher-down" 2>/dev/null)"
echo "-- 4s later, take-over arm still waiting quietly: $(kill -0 $ARM 2>/dev/null && echo yes || echo no); output now:"; sed 's/^/     /' "$LAB/takeover.out"
if ! kill -0 $ARM 2>/dev/null; then
  echo "-- take-over arm exited; the host re-arms as it does after 'a close without a wake':"
  $E FM_ARM_CONFIRM_TIMEOUT=10 "$BIN/fm-watch-arm.sh" > "$LAB/rearm.out" 2>&1 &
  RA=$!; sleep 6; sed 's/^/     /' "$LAB/rearm.out"; kill -TERM $RA 2>/dev/null; wait $RA 2>/dev/null
fi
echo "-- cycle ledger (.watch-cycle-exits.log):"; sed 's/^/     /' "$LAB/state/.watch-cycle-exits.log"
kill -TERM $ARM 2>/dev/null; wait $ARM 2>/dev/null; kill -TERM $OWNER 2>/dev/null; wait $OWNER 2>/dev/null
for p in $(cat "$LAB/state/.watch.lock/pid" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
sleep 1
$REAL -L fm-lab kill-server 2>/dev/null
rm -rf "$LAB"
echo "== [$LABEL] lab torn down"
