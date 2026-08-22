#!/usr/bin/env bash
# orch-state.sh — read/update the orchestrator-owned ```json orchestrator-state``` PR comment,
# the sole ledger for attempt/round caps.
#
#   orch-state.sh get   <pr>                 # print current state JSON (defaults if absent)
#   orch-state.sh bump  <pr> <key>           # increment key; REFUSES with exit 3 if already at cap
#   orch-state.sh reset <pr> <key>           # set key to 0 (e.g. rebaseAttempts after a success)
#
# keys: fixAttempts | reviewRounds | rebaseAttempts | codexRequests. Cap via $MAX_ATTEMPTS (default 2).
# codexRequests counts "@codex review" triggers for the PR's *current* head commit — reset it
# whenever new commits land (fix/rework/rebase push), since those need a fresh codex review.
# Exit codes: 0 ok, 3 cap reached (escalate to the human), 1 anything else.
#
# Concurrency: read-modify-write on a comment, no CAS — safe only under the pipeline's
# single-dispatcher assumption (one tick at a time). Never run two dispatchers against
# the same repo; concurrent bumps can lose increments.
set -euo pipefail
source "$(dirname "$0")/common.sh"

CMD="${1:-}"; PR="${2:-}"; KEY="${3:-}"
[ -n "$CMD" ] && [ -n "$PR" ] || die "usage: orch-state.sh get|bump|reset <pr> [key]"
DEFAULT='{"fixAttempts":0,"reviewRounds":0,"rebaseAttempts":0,"codexRequests":0}'
SLUG="$(repo_slug)"

find_comment_id() {
  gh api "repos/$SLUG/issues/$PR/comments" --paginate \
    --jq '.[] | select(.body | contains("```json orchestrator-state")) | .id' \
    | tail -1
}

extract_json() { # stdin: comment body → the fenced JSON
  awk '/```json orchestrator-state/{f=1;next} /```/{if(f)exit} f' | jq -c '.'
}

# API failures must abort (exit 1), never silently read as "no ledger yet" — a rate-limit
# blip that zeroed the ledger would let a capped PR look fresh.
comment_id="$(find_comment_id)"
if [ -n "$comment_id" ]; then
  body="$(gh api "repos/$SLUG/issues/comments/$comment_id" --jq .body)"
  state="$(echo "$body" | extract_json 2>/dev/null)" || die "could not parse orchestrator-state comment $comment_id on PR #$PR"
else
  state="$DEFAULT"
fi
# Fill any missing keys
state=$(echo "$state" | jq --argjson d "$DEFAULT" '$d + .')

case "$CMD" in
  get)
    echo "$state"
    ;;
  bump|reset)
    [ -n "$KEY" ] || die "usage: orch-state.sh $CMD <pr> <key>"
    echo "$state" | jq -e --arg k "$KEY" 'has($k)' >/dev/null || die "unknown key: $KEY"
    cur=$(echo "$state" | jq -r --arg k "$KEY" '.[$k]')
    if [ "$CMD" = "bump" ]; then
      if [ "$cur" -ge "$MAX_ATTEMPTS" ]; then
        echo "CAP REACHED: $KEY=$cur (max $MAX_ATTEMPTS) on PR #$PR — escalate to the human." >&2
        exit 3
      fi
      new_state=$(echo "$state" | jq -c --arg k "$KEY" '.[$k] += 1')
    else
      new_state=$(echo "$state" | jq -c --arg k "$KEY" '.[$k] = 0')
    fi
    body=$(printf '```json orchestrator-state\n%s\n```\n(orchestrator)' "$new_state")
    if [ -n "$comment_id" ]; then
      gh api -X PATCH "repos/$SLUG/issues/comments/$comment_id" -f body="$body" >/dev/null
    else
      gh pr comment "$PR" --body "$body" >/dev/null
    fi
    echo "$new_state"
    ;;
  *) die "unknown command: $CMD" ;;
esac
