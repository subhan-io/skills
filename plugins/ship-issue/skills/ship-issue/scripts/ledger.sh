#!/usr/bin/env bash
# ledger.sh — append one event to the ship-issue usage ledger.
#
#   ledger.sh event=run-start issue=397 repo=owner/name tier=standard cwd="$PWD"
#   ledger.sh event=phase run=<id> issue=397 phase=plan-approved
#   ledger.sh event=run-end run=<id> issue=397 outcome=pr-open pr=443 chunks=2 \
#             reviewRounds=1 findingsValid=2 findingsInvalid=1 verifyRetries=0
#
# Every key=value pair becomes a JSON field; a UTC timestamp is added as `ts`.
# Values that parse as JSON (numbers, objects, booleans) keep their type.
#
# run-start extras:
#   - `issue` must be present and not 0 (an adhoc slug is fine).
#   - A `run` id is generated if none was passed, and printed on stdout. Pass it
#     back as run=<id> on every later event of the run (and as --run to
#     run-codex.sh) so events join exactly, not by issue + time window.
#   - `claudeSession` (this orchestrator session's transcript file) is recorded
#     automatically from the newest transcript under the cwd's project dir, so
#     usage-report.sh can sum exactly this session instead of a time window.
#     Pass claudeSession=<file.jsonl> explicitly to override.
#
# The ledger is machine-central (one file across all repos and sessions) so a later
# session can audit cost per run: see usage-report.sh.
set -euo pipefail

LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
mkdir -p "$(dirname "$LEDGER")"

event="" issue="" run_id="" cwd="" claude_session="" phase="" outcome=""
kvs=()
for kv in "$@"; do
  key="${kv%%=*}"; val="${kv#*=}"
  if [ -z "$key" ] || [ "$key" = "$kv" ]; then
    echo "ledger.sh: argument '$kv' is not key=value" >&2; exit 1
  fi
  case "$key" in
    event) event="$val" ;;
    issue) issue="$val" ;;
    run) run_id="$val" ;;
    cwd) cwd="$val" ;;
    claudeSession) claude_session="$val" ;;
    phase) phase="$val" ;;
    outcome) outcome="$val" ;;
  esac
  kvs+=("$kv")
done

# Only the phases the SKILL defines may be logged; an improvised phase name is a
# step the skill doesn't have, and it breaks usage-report.sh's per-step attribution.
if [ "$event" = "phase" ]; then
  case "$phase" in
    plan-approved|planner-done|verify-failed|review-requested|review-settled) ;;
    *) echo "ledger.sh: unknown phase '$phase' (allowed: plan-approved planner-done verify-failed review-requested review-settled)" >&2
       exit 1 ;;
  esac
fi

if [ "$event" = "run-end" ]; then
  case "$outcome" in
    pr-open|stopped|split) ;;
    *) echo "ledger.sh: run-end requires outcome=<pr-open|stopped|split>, got '$outcome'" >&2
       exit 1 ;;
  esac
fi

if [ "$event" = "run-start" ]; then
  if [ -z "$issue" ] || [ "$issue" = "0" ]; then
    echo "ledger.sh: run-start requires issue=<number or adhoc slug>, got '$issue'" >&2
    exit 1
  fi
  if [ -z "$run_id" ]; then
    # Timestamp alone collides when two orchestrators start the same issue in the
    # same second, so add entropy: uuid if available, else PID + urandom hex.
    rand="$( (cat /proc/sys/kernel/random/uuid 2>/dev/null || true) | cut -c1-8 )"
    [ -n "$rand" ] || rand="$$-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    run_id="r-$(date -u +%Y%m%dT%H%M%SZ)-${issue}-${rand}"
    kvs+=("run=$run_id")
  fi
  if [ -z "$claude_session" ] && [ -n "$cwd" ]; then
    proj_dir="$HOME/.claude/projects/$(echo "$cwd" | sed 's|[/.]|-|g')"
    newest="$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1 || true)"
    [ -n "$newest" ] && kvs+=("claudeSession=$(basename "$newest")")
  fi
fi

args=(-n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
expr='{ts:$ts}'
i=0
for kv in "${kvs[@]}"; do
  key="${kv%%=*}"; val="${kv#*=}"
  # Values that parse as JSON (numbers, objects, booleans, null) keep their type;
  # everything else is a string. `jq -e 'true'` (not `jq -e .`) so a literal
  # `null`/`false` counts as valid JSON — `jq -e .` exits 1 on those and used to
  # store tokens=null as the string "null".
  if jq -e 'true' >/dev/null 2>&1 <<<"$val"; then
    args+=(--arg "k$i" "$key" --argjson "v$i" "$val")
  else
    args+=(--arg "k$i" "$key" --arg "v$i" "$val")
  fi
  expr="$expr + {(\$k$i): \$v$i}"
  i=$((i + 1))
done

jq "${args[@]}" "$expr" >> "$LEDGER"
[ "$event" = "run-start" ] && echo "$run_id" || true
