#!/usr/bin/env bash
# claim-issue.sh <issue> — atomic claim (SKILL step 4.1 + 4.3 in one call).
# The RESERVATION is the remote branch: GitHub ref creation is atomic, so exactly one
# contender can create refs/heads/agent/issue-<n>. The claim label is applied after and is
# informational (board filtering), not the lock.
# Exit codes: 0 claimed, 2 lost the race (reason on stderr — skip and note in summary), 1 error.
set -euo pipefail
source "$(dirname "$0")/common.sh"

N="${1:-}"; [ -n "$N" ] || die "usage: claim-issue.sh <issue-number>"
BRANCH="${BRANCH_PREFIX}${N}"
SLUG="$(repo_slug)"

# Cheap pre-checks (fast-fail; the ref create below is the actual lock)
if git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "SKIP: branch $BRANCH already exists on origin" >&2; exit 2
fi
labels=$(gh issue view "$N" --json labels --jq '[.labels[].name]')
if echo "$labels" | jq -e --arg l "$CLAIM_LABEL" 'index($l) != null' >/dev/null; then
  echo "SKIP: issue #$N already labeled $CLAIM_LABEL" >&2; exit 2
fi

# Atomic reservation: create the branch at the base branch head. 422 = someone else won.
base_sha=$(gh api "repos/$SLUG/git/ref/heads/$BASE_BRANCH" --jq .object.sha)
if ! gh api "repos/$SLUG/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$base_sha" >/dev/null 2>&1; then
  if git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
    echo "SKIP: lost the race — $BRANCH was created by another contender" >&2; exit 2
  fi
  die "could not create $BRANCH (API error, not a race)"
fi

# If the label write fails, roll back the reservation — an unlabelled issue with a leftover
# branch would look dispatchable forever while every re-claim bounces off the existing ref.
if ! gh issue edit "$N" --add-label "$CLAIM_LABEL" >/dev/null; then
  gh api -X DELETE "repos/$SLUG/git/refs/heads/$BRANCH" >/dev/null 2>&1 \
    || echo "WARN: rollback failed — delete branch $BRANCH manually or the issue stays stuck" >&2
  die "label write failed on #$N; reservation branch rolled back"
fi
echo "claimed #$N (branch $BRANCH created at $base_sha, $CLAIM_LABEL added)"
