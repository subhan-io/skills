#!/usr/bin/env bash
# merge.sh — merge an AFK run's PR, only when it has passed the merge test.
#
#   merge.sh --repo <owner/name> --pr <n> --run <id> --issue <n> \
#            [--timeout <minutes, default 45>] [--round2-skipped "<why>"]
#
# The merge test, checked here so that no prose rule has to hold it:
#   - the PR is open and not a draft;
#   - a review round settled for this run (review.sh logs it), and a round 2
#     settled when commits landed after round 1 settled: those commits are
#     round 1's fixes. When they were not review fixes (a CI fix, a repo-notes
#     commit), say so with --round2-skipped "<why>";
#   - the head commit's checks are green, waiting for them through ci-wait.sh.
# Then it squash-merges with --match-head-commit, so a push after the green
# check cannot merge unchecked, and deletes the branch. A base that is not the
# repository's default branch (an epic's integration branch) does not close the
# issue on merge, so the script closes it.
#
# Prints one line and exits:
#   0  merged <sha> base=<base> closed=<issue|no>
#   1  red ...       (ci-wait.sh's line: the checks failed)
#   2  timeout ...   (ci-wait.sh's line: the checks did not settle)
#   3  refused <reason>
#   4  bad arguments
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
repo="" pr="" run="" issue="" timeout=45 skip_reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --round2-skipped) skip_reason="$2"; shift 2 ;;
    *) echo "merge.sh: unknown argument $1" >&2; exit 4 ;;
  esac
done
for v in repo pr run issue; do
  [ -n "${!v}" ] || { echo "merge.sh: --$v is required" >&2; exit 4; }
done
refuse() { echo "refused $*"; exit 3; }

info="$(gh pr view "$pr" -R "$repo" --json state,isDraft,baseRefName,commits)"
[ "$(jq -r .state <<<"$info")" = "OPEN" ] || refuse "PR #$pr is $(jq -r .state <<<"$info"), not open"
[ "$(jq -r .isDraft <<<"$info")" = "false" ] || refuse "PR #$pr is a draft"
base="$(jq -r .baseRefName <<<"$info")"

[ -f "$LEDGER" ] || refuse "no ledger at $LEDGER"
rounds="$(jq -s -c --arg r "$run" \
  '[.[] | select(.run == $r and .phase == "review-settled")] | sort_by(.round)' "$LEDGER")"
[ "$(jq 'length' <<<"$rounds")" -gt 0 ] \
  || refuse "no review round settled for run $run: run step 7's review before merging"
if [ "$(jq '[.[].round] | max' <<<"$rounds")" -lt 2 ] && [ -z "$skip_reason" ]; then
  settled="$(jq -r '.[0].ts' <<<"$rounds")"
  after="$(jq --arg t "$settled" '[.commits[] | select(.committedDate > $t)] | length' <<<"$info")"
  [ "$after" -eq 0 ] || refuse "$after commit(s) landed after review round 1 settled ($settled):" \
    "run round 2, or pass --round2-skipped \"<why>\" when they were not review fixes"
fi

set +e
ci="$("$here/ci-wait.sh" --repo "$repo" --pr "$pr" --timeout "$timeout")"
status=$?
set -e
if [ "$status" -ne 0 ]; then echo "$ci"; exit "$status"; fi
sha="$(awk '{print $2}' <<<"$ci")"

if ! out="$(gh pr merge "$pr" -R "$repo" --squash --delete-branch --match-head-commit "$sha" 2>&1)"; then
  refuse "gh pr merge failed: $(tr '\n' ' ' <<<"$out")"
fi

closed=no
default="$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name)"
if [ "$base" != "$default" ] && [[ "$issue" =~ ^[0-9]+$ ]]; then
  gh issue close "$issue" -R "$repo" --reason completed >/dev/null
  closed="$issue"
fi
echo "merged $sha base=$base closed=$closed"
