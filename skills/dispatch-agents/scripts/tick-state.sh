#!/usr/bin/env bash
# tick-state.sh — one-call snapshot of world state for a dispatcher tick (steps 1–3 reads).
# Read-only. Emits a single JSON object:
# {
#   issues: [{number,title,body,claimed,blockedBy:[{issue,closed}],hasOpenPr,dispatchable,staleClaimCandidate}],
#   prs:    [{number,issue,branch,url,readyForReview,mergeable,classification,staleBehindMaster,orchestratorState,codex}],
#   recentMerged: [{number,branch,issue}]
# }
# classification: conflict | pending | red | green  (mergeable beats checks; UNKNOWN and
# "no checks reported" are pending — never derived from bare exit codes).
# codex: the codex-review.sh status snapshot (not-requested|awaiting|arriving|settled), resolved
# only for green PRs — the one place it gates anything — and null everywhere else.
# staleClaimCandidate means: claimed, no open agent PR. The dispatcher must still subtract
# implementers it knows are in flight this session before treating it as stale.
set -euo pipefail
source "$(dirname "$0")/common.sh"

SLUG="$(repo_slug)"

# --- Open ready issues + claimed issues ---
ready_issues=$(gh issue list --label "$READY_LABEL" --label "$APP_LABEL" --state open \
  --json number,title,body,labels --limit 100)
claimed_issues=$(gh issue list --label "$CLAIM_LABEL" --label "$APP_LABEL" --state open \
  --json number,title,body,labels --limit 100)
all_issues=$(jq -s 'add | unique_by(.number)' <(echo "$ready_issues") <(echo "$claimed_issues"))

# --- All remote agent branches (reservations), for orphan detection ---
agent_branches=$(git ls-remote origin "refs/heads/${BRANCH_PREFIX}*" 2>/dev/null \
  | sed "s|.*refs/heads/${BRANCH_PREFIX}||" || true)

# --- Open + recently merged agent PRs ---
open_prs=$(gh pr list --state open --json number,headRefName,labels,url --limit 100 \
  | jq --arg p "$BRANCH_PREFIX" '[.[] | select(.headRefName | startswith($p))]')
recent_merged=$(gh pr list --state merged --json number,headRefName --limit 30 \
  | jq --arg p "$BRANCH_PREFIX" '[.[] | select(.headRefName | startswith($p))
      | {number, branch: .headRefName, issue: (.headRefName | ltrimstr($p) | tonumber? // null)}]')

# --- Per-PR enrichment ---
pr_objs="[]"
for pr in $(echo "$open_prs" | jq -r '.[].number'); do
  branch=$(echo "$open_prs" | jq -r --argjson n "$pr" '.[] | select(.number==$n) | .headRefName')
  url=$(echo "$open_prs" | jq -r --argjson n "$pr" '.[] | select(.number==$n) | .url')
  ready=$(echo "$open_prs" | jq --argjson n "$pr" --arg l "$REVIEW_LABEL" \
    '[.[] | select(.number==$n) | .labels[].name] | index($l) != null')
  issue=$(echo "$branch" | sed "s|^$BRANCH_PREFIX||")

  mergeable=$(gh pr view "$pr" --json mergeable --jq .mergeable)

  if [ "$mergeable" = "CONFLICTING" ]; then
    classification="conflict"
  elif [ "$mergeable" = "UNKNOWN" ]; then
    classification="pending"
  else
    # gh pr checks exits non-zero for both "failing" and "no checks" — ignore exit code, read JSON.
    checks=$(gh pr checks "$pr" --json bucket 2>/dev/null || echo "[]")
    echo "$checks" | jq -e 'type=="array"' >/dev/null 2>&1 || checks="[]"
    n_total=$(echo "$checks" | jq 'length')
    n_fail=$(echo "$checks" | jq '[.[] | select(.bucket=="fail" or .bucket=="cancel")] | length')
    # green is the strict arm: every check must be pass/skipping. Anything else — pending,
    # queued/in-progress, or a bucket value we don't recognize — stays pending.
    n_done=$(echo "$checks" | jq '[.[] | select(.bucket=="pass" or .bucket=="skipping")] | length')
    if [ "$n_total" -eq 0 ]; then classification="pending"        # no checks reported yet
    elif [ "$n_fail" -gt 0 ]; then classification="red"
    elif [ "$n_done" -eq "$n_total" ]; then classification="green"
    else classification="pending"; fi
  fi

  behind=$(gh api "repos/$SLUG/compare/$branch...$BASE_BRANCH" --jq '.ahead_by' 2>/dev/null || echo "null")
  # base branch ahead of branch's merge-base view: compare branch...<base> ahead_by = commits on the base branch not on branch
  if [ "$behind" = "null" ]; then stale="null"; elif [ "$behind" -gt 0 ]; then stale=true; else stale=false; fi

  # null (not zeros) on read failure — a rate-limit blip must not make a capped PR look fresh.
  # Cap enforcement doesn't depend on this snapshot anyway: orch-state.sh bump re-reads live state.
  ostate=$("$SCRIPT_DIR/orch-state.sh" get "$pr" 2>/dev/null || echo 'null')

  # Codex state costs 3 extra API calls, and only green PRs are ever gated on it.
  if [ "$classification" = "green" ]; then
    codex=$("$SCRIPT_DIR/codex-review.sh" status "$pr" 2>/dev/null || echo 'null')
  else
    codex='null'
  fi

  pr_objs=$(echo "$pr_objs" | jq \
    --argjson n "$pr" --arg branch "$branch" --arg url "$url" --argjson ready "$ready" \
    --arg issue "$issue" --arg mergeable "$mergeable" --arg cls "$classification" \
    --argjson stale "$stale" --argjson ostate "$ostate" --argjson codex "$codex" \
    '. + [{number:$n, issue:($issue|tonumber? // null), branch:$branch, url:$url,
           readyForReview:$ready, mergeable:$mergeable, classification:$cls,
           staleBehindMaster:$stale, orchestratorState:$ostate, codex:$codex}]')
done

# --- Per-issue enrichment: blockers, claims, dispatchability ---
issue_objs="[]"
for n in $(echo "$all_issues" | jq -r '.[].number'); do
  row=$(echo "$all_issues" | jq --argjson n "$n" '.[] | select(.number==$n)')
  body=$(echo "$row" | jq -r '.body // ""')
  claimed=$(echo "$row" | jq --arg l "$CLAIM_LABEL" '[.labels[].name] | index($l) != null')

  # Parse "#N" refs inside the "## Blocked by" section (until next ## heading)
  blockers_json="[]"
  blocker_nums=$(echo "$body" | awk '/^## Blocked by/{f=1;next} /^## /{f=0} f' | grep -oE '#[0-9]+' | tr -d '#' | sort -u || true)
  open_blocker=false
  for b in $blocker_nums; do
    state=$(gh issue view "$b" --json state --jq .state 2>/dev/null || echo "UNKNOWN")
    closed=$([ "$state" = "CLOSED" ] && echo true || echo false)
    [ "$closed" = "false" ] && open_blocker=true
    blockers_json=$(echo "$blockers_json" | jq --argjson b "$b" --argjson c "$closed" '. + [{issue:$b, closed:$c}]')
  done

  has_pr=$(echo "$pr_objs" | jq --argjson n "$n" '[.[] | select(.issue==$n)] | length > 0')
  branch_exists=false
  echo "$agent_branches" | grep -qx "$n" && branch_exists=true
  # Orphaned reservation: branch exists but no label and no PR — a claim died between its
  # two writes. Not dispatchable until the branch is cleaned up (see SKILL stale-claim rule).
  orphaned=false
  if [ "$branch_exists" = "true" ] && [ "$claimed" = "false" ] && [ "$has_pr" = "false" ]; then orphaned=true; fi
  dispatchable=false
  if [ "$claimed" = "false" ] && [ "$has_pr" = "false" ] && [ "$branch_exists" = "false" ] && [ "$open_blocker" = "false" ]; then dispatchable=true; fi
  stale_claim=false
  if [ "$claimed" = "true" ] && [ "$has_pr" = "false" ]; then stale_claim=true; fi

  issue_objs=$(echo "$issue_objs" | jq \
    --argjson row "$row" --argjson claimed "$claimed" --argjson blockers "$blockers_json" \
    --argjson hasPr "$has_pr" --argjson d "$dispatchable" --argjson sc "$stale_claim" \
    --argjson orphaned "$orphaned" \
    '. + [{number:$row.number, title:$row.title, body:$row.body, claimed:$claimed,
           blockedBy:$blockers, hasOpenPr:$hasPr, dispatchable:$d, staleClaimCandidate:$sc,
           orphanedReservation:$orphaned}]')
done

# Catch-all: agent branches matching neither a surveyed issue nor an open PR — reservations
# whose issue fell out of both queries (ready label removed, issue closed by hand, etc.).
# The dispatcher must investigate these; a commit-less one with a closed/unlabelled issue is
# a leftover to delete, one with commits may be unharvested work.
# Branches of recently-merged PRs are excluded — those are ordinary undeleted-branch leftovers.
unmatched=$(jq -n --argjson issues "$issue_objs" --argjson prs "$pr_objs" \
  --argjson merged "$recent_merged" --arg branches "$agent_branches" \
  '($branches | split("\n") | map(select(length>0) | tonumber? // empty))
   - [$issues[].number] - [$prs[].issue] - [$merged[].issue]')

jq -n --argjson issues "$issue_objs" --argjson prs "$pr_objs" --argjson merged "$recent_merged" \
  --argjson unmatched "$unmatched" \
  '{issues:$issues, prs:$prs, recentMerged:$merged, unmatchedAgentBranches:$unmatched}'
