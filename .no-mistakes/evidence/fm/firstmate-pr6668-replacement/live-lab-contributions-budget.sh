#!/usr/bin/env bash
# Live lab: real bin/fm-contributions.sh poll against real GitHub (gh), with a
# PATH shim that injects forge faults in front of the real gh.
set -u
ROOT=$1
URL=https://github.com/kunchenguid/firstmate/pull/6668
CORE='api repos/kunchenguid/firstmate/pulls/6668'
REAL_GH=$(command -v gh)
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export FM_HOME="$LAB" FORGE="$LAB/forge" REAL_GH
mkdir -p "$FORGE" "$LAB/fakebin" "$LAB/data/delivery"
printf '#!/bin/sh\nexit 1\n' > "$LAB/fakebin/tmux"
cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
trap 'printf "%s end pid=%s rc=%s\n" "$(date +%s)" $$ $? >> "$FORGE/calls.ts"' EXIT; printf '%s\n' "$*" >> "$FORGE/calls"; printf '%s pid=%s ppid=%s %s\n' "$(date +%s)" $$ $PPID "$*" >> "$FORGE/calls.ts"
case "$(cat "$FORGE/fault" 2>/dev/null):$*" in
  once:'api repos/kunchenguid/firstmate/pulls/6668')
    if [ ! -e "$FORGE/spent" ]; then : > "$FORGE/spent"; echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1; fi ;;
  slowfail:'api repos/kunchenguid/firstmate/pulls/6668')
    sleep 4; echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1 ;;
  failhang:'api repos/kunchenguid/firstmate/pulls/6668')
    if [ ! -e "$FORGE/spent" ]; then : > "$FORGE/spent"; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    sleep 10; exit 1 ;;
  always:'api repos/kunchenguid/firstmate/pulls/6668')
    echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1 ;;
esac
exec "$REAL_GH" "$@"
SH
chmod +x "$LAB/fakebin/"*
export PATH="$LAB/fakebin:$PATH"
printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution delivery %s (repo: firstmate) (kind: ship)\n' "$URL" > "$LAB/data/backlog.md"
jq -n --arg url "$URL" '{schema:"fm-contributions.v1",task:"delivery",records:[{url:$url,kind:"pr",
  checked_at:"2026-09-15T08:00:00Z",error:null,pending:[],seen:[],verdict:null,observation:null}]}' \
  > "$LAB/data/delivery/contributions.json"
rec() { jq -c '.records[0] | {checked_at, error, head: .observation.head, state: .observation.state}' "$LAB/data/delivery/contributions.json"; }
run() {  # label fault
  rm -f "$FORGE/calls" "$FORGE/spent"; printf '%s\n' "$2" > "$FORGE/fault"
  echo "=== $1  (injected fault: $2)"
  s0=$(date +%s); out=$("$ROOT/bin/fm-contributions.sh" poll 2>&1); rc=$?; echo "    poll started $s0, took $(( $(date +%s) - s0 ))s"
  echo "    poll exit=$rc"
  echo "    poll stdout/stderr (a wake line means the primary is woken): ${out:-<empty>}"
  echo "    core PR reads ($CORE): $(grep -cFx "$CORE" "$FORGE/calls")   total gh calls: $(wc -l < "$FORGE/calls" | tr -d ' ')"
  echo "    record: $(rec)"
}
echo "lab home: $LAB"
show() { echo "    timestamped gh calls:"; sed "s/^/      /" "$FORGE/calls.ts"; rm -f "$FORGE/calls.ts"; }
jq '.records[0].error=null' "$LAB/data/delivery/contributions.json" > "$LAB/t" && mv "$LAB/t" "$LAB/data/delivery/contributions.json"
FM_CONTRIBUTIONS_BUDGET=18 run "Scenario G1 (budget 18s): a slow failing first read leaves <15s, so no retry starts" slowfail; show
jq '.records[0].error=null' "$LAB/data/delivery/contributions.json" > "$LAB/t" && mv "$LAB/t" "$LAB/data/delivery/contributions.json"
run "Scenario G2 (budget 20s): first read 404s, the retry hangs and is killed at the read bound" failhang; show
rm -rf "$LAB"; echo "lab removed"
