#!/usr/bin/env bash
# epic-wait.sh — block until at least one dispatched AFK run has reported.
#
#   epic-wait.sh --repo <owner/name> [--interval 60] [--timeout 14400] \
#                <issue>@<dispatch-time> [<issue>@<dispatch-time> ...]
#
# A dispatched ship-issue run posts its handover as a comment on its issue, as
# its last action. This polls each in-flight issue for a comment created after
# that issue's dispatch time (UTC ISO-8601, e.g. 2026-09-16T00:04:00Z) and exits
# once one or more have arrived, printing one line per finished issue:
#
#   done issue=660 outcome=merged comment=https://github.com/.../issues/660#issuecomment-1
#
# `outcome` is the run's run-end in the ledger, or `unknown` when the run posted
# without one. Exit 0 when something finished, 4 on timeout (it prints
# `timeout waiting=<issues>`), 1 on bad arguments.
#
# Run it backgrounded (run_in_background) so the tick spends no turns while it
# waits: the harness wakes the tick when it exits. A chain of ScheduleWakeup
# calls does not survive — T3 stops a session idle for 30 minutes.
set -euo pipefail

LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
repo="" interval=60 timeout=14400
pending=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    *@*) pending+=("$1"); shift ;;
    *) echo "epic-wait.sh: unknown argument $1 (issues are <n>@<dispatch-time>)" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] && [ ${#pending[@]} -gt 0 ] || {
  echo "epic-wait.sh: --repo and at least one <issue>@<dispatch-time> are required" >&2; exit 1; }

deadline=$(( $(date +%s) + timeout ))
while :; do
  found=0
  for entry in "${pending[@]}"; do
    issue="${entry%%@*}" since="${entry#*@}"
    url="$(gh api "repos/$repo/issues/$issue/comments?since=$since&per_page=100" \
            --jq "[.[] | select(.created_at > \"$since\")] | last | .html_url // empty" 2>/dev/null || true)"
    [ -n "$url" ] || continue
    outcome="unknown"
    if [ -f "$LEDGER" ]; then
      outcome="$(jq -r --arg i "$issue" --arg s "$since" \
        'select(.event == "run-end" and (.issue|tostring) == $i and .ts >= $s) | .outcome' \
        "$LEDGER" | tail -1)"
      [ -n "$outcome" ] || outcome="unknown"
    fi
    echo "done issue=$issue outcome=$outcome comment=$url"
    found=1
  done
  [ "$found" = 1 ] && exit 0
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timeout waiting=$(printf '%s ' "${pending[@]%%@*}" | sed 's/ $//')"
    exit 4
  fi
  sleep "$interval"
done
