#!/usr/bin/env bash
# ledger.sh — append one event to the ship-issue usage ledger.
#
#   ledger.sh event=run-start issue=397 repo=owner/name tier=standard cwd="$PWD"
#   ledger.sh event=run-end   issue=397 outcome=pr-open pr=443 chunks=2 reviewRounds=1
#
# Every key=value pair becomes a JSON string field; a UTC timestamp is added as `ts`.
# The ledger is machine-central (one file across all repos and sessions) so a later
# session can audit cost per run: see usage-report.sh.
set -euo pipefail

LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
mkdir -p "$(dirname "$LEDGER")"

args=(-n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
expr='{ts:$ts}'
i=0
for kv in "$@"; do
  key="${kv%%=*}"; val="${kv#*=}"
  if [ -z "$key" ] || [ "$key" = "$kv" ]; then
    echo "ledger.sh: argument '$kv' is not key=value" >&2; exit 1
  fi
  # Values that parse as JSON (numbers, objects, booleans) keep their type;
  # everything else is a string.
  if jq -e . >/dev/null 2>&1 <<<"$val"; then
    args+=(--arg "k$i" "$key" --argjson "v$i" "$val")
  else
    args+=(--arg "k$i" "$key" --arg "v$i" "$val")
  fi
  expr="$expr + {(\$k$i): \$v$i}"
  i=$((i + 1))
done

jq "${args[@]}" "$expr" >> "$LEDGER"
