#!/usr/bin/env bash
# worktree.sh <issue> — create or inspect the agent worktree for an issue (SKILL step 4.4 setup).
# Creates .claude/worktrees/agent-issue-<n> on branch agent/issue-<n> (from origin/<branch> if it
# exists, else origin/<base>). If the worktree already exists it is NOT touched — the script just
# reports its state so the dispatcher/implementer can decide to build on or reset it deliberately.
# Prints JSON: {path, branch, created, dirty, unpushedCommits, head}
set -euo pipefail
source "$(dirname "$0")/common.sh"

N="${1:-}"; [ -n "$N" ] || die "usage: worktree.sh <issue-number>"
BRANCH="${BRANCH_PREFIX}${N}"
ROOT="$(main_repo_root)"
WT="$ROOT/.claude/worktrees/agent-issue-$N"

git -C "$ROOT" fetch origin --quiet

created=false
if [ ! -d "$WT" ]; then
  if git -C "$ROOT" ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
    git -C "$ROOT" worktree add "$WT" -B "$BRANCH" "origin/$BRANCH" --quiet
  else
    git -C "$ROOT" worktree add "$WT" -b "$BRANCH" "origin/$BASE_BRANCH" --quiet
  fi
  created=true
fi

dirty=false
[ -n "$(git -C "$WT" status --porcelain)" ] && dirty=true
head=$(git -C "$WT" rev-parse --short HEAD)
if git -C "$WT" rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
  unpushed=$(git -C "$WT" rev-list --count "origin/$BRANCH..HEAD")
else
  unpushed=$(git -C "$WT" rev-list --count "origin/$BASE_BRANCH..HEAD")
fi

jq -n --arg path "$WT" --arg branch "$BRANCH" --argjson created "$created" \
      --argjson dirty "$dirty" --argjson unpushed "$unpushed" --arg head "$head" \
  '{path:$path, branch:$branch, created:$created, dirty:$dirty, unpushedCommits:$unpushed, head:$head}'
