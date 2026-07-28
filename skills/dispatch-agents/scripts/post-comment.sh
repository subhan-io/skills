#!/usr/bin/env bash
# post-comment.sh (--pr|--issue) <number> <role-tag> [--fence <block-name>] — post a comment with
# the pipeline's authorship convention. Body on stdin.
#   role-tag: orchestrator | "rebase agent" | "rework agent, round 2" | ...
#   --fence review-verdict|agent-report|files-claim: wrap stdin in ```json <name>``` and validate
#           it is JSON first.
set -euo pipefail
source "$(dirname "$0")/common.sh"

KIND="${1:-}"; N="${2:-}"; TAG="${3:-}"; FENCE=""
[ "${4:-}" = "--fence" ] && FENCE="${5:-}"
{ [ "$KIND" = "--pr" ] || [ "$KIND" = "--issue" ]; } && [ -n "$N" ] && [ -n "$TAG" ] \
  || die "usage: post-comment.sh (--pr|--issue) <number> <role-tag> [--fence <block-name>] < body"

BODY="$(cat)"
if [ -n "$FENCE" ]; then
  echo "$BODY" | jq -e . >/dev/null || die "--fence requires valid JSON on stdin"
  BODY=$(printf '```json %s\n%s\n```' "$FENCE" "$BODY")
fi
BODY=$(printf '%s\n\n(%s)' "$BODY" "$TAG")

if [ "$KIND" = "--pr" ]; then
  gh pr comment "$N" --body "$BODY" >/dev/null
else
  gh issue comment "$N" --body "$BODY" >/dev/null
fi
echo "commented on $KIND #$N as ($TAG)"
