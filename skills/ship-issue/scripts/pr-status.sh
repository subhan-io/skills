#!/usr/bin/env bash
# pr-status.sh — the between-steps snapshot: is this PR green, is it behind the base branch,
# does it conflict, and where is codex up to.
#
#   pr-status.sh <pr>
#
# `classification` collapses the precedence rules so callers never re-derive them from a bare
# `gh pr checks` exit code:
#   conflict — GitHub computed mergeable:CONFLICTING. Authoritative over check state: a red
#              check on a conflicted branch is noise, the conflict is the thing to fix.
#   pending  — checks queued or still running, or mergeability not yet computed. Wait.
#   red      — a check actually failed.
#   green    — everything reported and passed.
set -euo pipefail
source "$(dirname "$0")/common.sh"

PR="${1:-}"
[ -n "$PR" ] || die "usage: pr-status.sh <pr>"
SLUG="$(repo_slug)"
BASE="$(default_branch)"

pr_json=$(gh pr view "$PR" --json number,headRefName,headRefOid,mergeable,mergeStateStatus,state,url,statusCheckRollup) \
  || die "cannot read PR #$PR"

# How far behind origin/<base> the PR head is. `gh` does not expose this, so compare directly.
git fetch origin --quiet "$BASE" 2>/dev/null || true
head_sha=$(echo "$pr_json" | jq -r .headRefOid)
behind=$(gh api "repos/$SLUG/compare/$head_sha...$BASE" --jq '.ahead_by' 2>/dev/null || echo null)

codex_state=$(CODEX_SETTLE_SECONDS="${CODEX_SETTLE_SECONDS:-120}" \
  "$(dirname "$0")/codex-wait.sh" status "$PR" --quiet 2>/dev/null || echo unknown)

echo "$pr_json" | jq \
  --argjson behind "${behind:-null}" --arg codex "$codex_state" --arg base "$BASE" '
  (.statusCheckRollup // []) as $c
| ([$c[] | select((.conclusion // "") | . == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED"
                  or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")] | length) as $failed
| ([$c[] | select((.status // "") != "COMPLETED" and (.state // "") == "")] | length) as $running
| {pr: .number, url, state, branch: .headRefName, headSha: .headRefOid,
   baseBranch: $base, behindBase: $behind,
   mergeable, mergeStateStatus,
   checks: {failed: $failed, running: $running, total: ($c | length)},
   codex: $codex,
   classification:
     (if .mergeable == "CONFLICTING" then "conflict"
      elif .mergeable == "UNKNOWN" or $running > 0 or ($c | length) == 0 then "pending"
      elif $failed > 0 then "red"
      else "green" end),
   needsRebase: (($behind != null and $behind > 0) or .mergeable == "CONFLICTING")}'
