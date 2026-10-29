#!/usr/bin/env bash
# Drive the real bin/fm-contributions.sh poll against a disposable home and a
# scripted fake GitHub (fault injected per scenario); print a transcript.
cd "$1"
# shellcheck disable=SC1090
PRE=$(mktemp); sed -e '/^failures=0$/,$d' -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$PWD/tests#g" tests/fm-contributions.test.sh > "$PRE"; . "$PRE"; rm -f "$PRE"
run() { # name fault [record-mutation]
  local name=$1 fault=$2 mut=${3:-} home out
  home=$(new_home "live-$name"); forge_home "$home"; wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'"$mut"
  [ "$fault" != retry-budget ] || /bin/date +%s > "$home/forge/clock"
  printf '%s\n' "$fault" > "$home/forge/fault"
  echo "=== scenario: $name (forge fault: $fault)"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll); echo "poll exit=$?"
  echo "stdout: ${out:-<empty - no wake>}"
  echo "core PR reads (api repos/o/r/pulls/8): $(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")"
  echo "record: $(jq -c '.records[0] | {checked_at, error}' "$home/data/delivery/contributions.json")"
  echo "wake-queue rows: $(wc -l < "$home/state/.wake-queue" 2>/dev/null || echo 0)"
  echo
}
run transient-failure retry-once
run persistent-failure fail-persist
run budget-cut-retry retry-budget
run open-episode fail-persist ' | .records[0].error="forge observation unavailable: core read exited 1 with 9s of budget left: HTTP 502"'
