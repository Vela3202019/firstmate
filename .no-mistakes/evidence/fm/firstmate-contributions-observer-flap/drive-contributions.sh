#!/usr/bin/env bash
# Drive the real bin/fm-contributions.sh poll against a disposable home whose
# forge (gh) fails transiently / persistently. Usage: drive-contributions.sh <repo-root>
set -u
R=$1
sed '/^failures=0/,$d' "$R/tests/fm-contributions.test.sh" > "$R/tests/.drive-lib.sh"
. "$R/tests/.drive-lib.sh"
rm -f "$R/tests/.drive-lib.sh"
fail() { echo "FAIL: $*"; }
for fault in retry-once fail-persist; do
  home=$(new_home "drive-$fault"); forge_home "$home"; wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  printf '%s\n' "$fault" > "$home/forge/fault"
  echo "=== fault=$fault (gh 'api repos/o/r/pulls/8' $( [ $fault = retry-once ] && echo 'fails once then succeeds' || echo 'always fails' ))"
  echo "\$ bin/fm-contributions.sh poll"
  out=$(with_home "$home" "$R/bin/fm-contributions.sh" poll); rc=$?
  echo "exit=$rc stdout=[${out}]"
  echo "gh pulls/8 reads: $(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")"
  echo "record: $(jq -c '.records[0] | {checked_at,error}' "$home/data/delivery/contributions.json")"
done
