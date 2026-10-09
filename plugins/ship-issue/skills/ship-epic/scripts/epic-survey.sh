#!/usr/bin/env bash
# epic-survey.sh — the epic's status table and next picks, in one call.
#
#   epic-survey.sh --repo <path> --epic <n> [--label hitl]
#
# Walks the epic's native sub-issues in their GitHub order, one level of nesting
# deep: a sub-issue with sub-issues of its own is a group, and its children are
# the work. For each work issue it joins the issue state, its open blockers
# (GitHub's blocked-by dependencies), and its PR against epic/<n> (one whose body
# says `Closes #<issue>`, or whose branch is named `.../<issue>-...`), with the
# PR's CI rollup.
#
# Prints a TSV table — issue, group, status, pr, ci, blockers, title — then:
#   horizon: <first open work issue labelled hitl, or none>
#   eligible: <open issues with no PR and no open blocker, up to the horizon>
#   in-review: <open issues with an open PR>
#
# status is one of: merged (PR merged, issue closed), merged-open (PR merged, issue
# not yet closed: its run is finishing, or it skipped the close), closed (closed
# without a merged PR), pr-open, blocked, eligible, beyond-horizon. A blocker
# counts as done once it is closed or its PR has merged.
set -euo pipefail

repo="" epic="" label="hitl"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --epic) epic="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    *) echo "epic-survey.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] && [ -n "$epic" ] || { echo "epic-survey.sh: --repo and --epic are required" >&2; exit 2; }
[ -d "$repo" ] || { echo "epic-survey.sh: --repo is a local checkout path, got '$repo'" >&2; exit 2; }
slug=$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner)
owner="${slug%/*}" name="${slug#*/}"

node_fields='number title state labels(first:20){nodes{name}} blockedBy(first:20){nodes{number state}}'
tree=$(gh api graphql -f query="query{repository(owner:\"$owner\",name:\"$name\"){issue(number:$epic){
  subIssues(first:50){nodes{$node_fields subIssues(first:50){nodes{$node_fields}}}}}}}")
prs=$(mktemp)
trap 'rm -f "$prs"' EXIT
# Bodies shrink to their closing references: whole bodies overflow jq's argv.
gh pr list -R "$slug" --base "epic/$epic" --state all --limit 200 \
  --json number,state,body,headRefName,statusCheckRollup \
  --jq 'map(.body = ([.body // "" | scan("(?i)(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?) #[0-9]+")] | join(" ")))' >"$prs"

jq -r --slurpfile prs "$prs" --arg label "$label" '
  ($prs[0]) as $prs |
  def ci: [.statusCheckRollup[]? | (.conclusion // .state // "") | ascii_upcase] as $c
          | if ($c | length) == 0 then "none"
            elif any($c[]; . == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ERROR") then "red"
            elif any($c[]; . == "" or . == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "EXPECTED") then "pending"
            else "green" end;
  def pr_for($n): [$prs[] | select(
        (.body // "" | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?) #" + ($n|tostring) + "\\b"))
        or (.headRefName | test("(^|/)" + ($n|tostring) + "-")))]
      | (map(select(.state == "MERGED")) + map(select(.state == "OPEN")) + .) | first;
  [.data.repository.issue.subIssues.nodes[]
   | . as $g
   | if (.subIssues.nodes | length) > 0
     then .subIssues.nodes[] | . + {group: ($g.number|tostring)}
     else . + {group: "-"} end]
  | . as $work
  | (map(select(.state == "OPEN" and any(.labels.nodes[]; .name | ascii_downcase == ($label | ascii_downcase))))
     | first | .number // null) as $horizon
  | ($work | map(.number) | index($horizon)) as $hidx
  | [$work[] | select(pr_for(.number).state == "MERGED") | .number] as $landed
  | [range(0; $work | length) as $i | $work[$i]
     | pr_for(.number) as $pr
     | [.blockedBy.nodes[] | select(.state == "OPEN") | .number | select(IN($landed[]) | not)] as $open
     | . + {pr: $pr, open_blockers: $open,
            status: (if $pr.state == "MERGED" then (if .state == "CLOSED" then "merged" else "merged-open" end)
                     elif .state == "CLOSED" then "closed"
                     elif $pr.state == "OPEN" then "pr-open"
                     elif ($open | length) > 0 then "blocked"
                     elif $hidx != null and $i > $hidx then "beyond-horizon"
                     else "eligible" end)}]
  | (["issue","group","status","pr","ci","blockers","title"] | @tsv),
    (.[] | [("#" + (.number|tostring)), .group, .status,
            (if .pr then "#" + (.pr.number|tostring) + " " + (.pr.state|ascii_downcase) else "-" end),
            (if .pr then (.pr | ci) else "-" end),
            (if (.open_blockers | length) > 0 then (.open_blockers | map("#" + tostring) | join(",")) else "-" end),
            .title] | @tsv),
    "",
    "horizon: " + (if $horizon then "#" + ($horizon|tostring) else "none" end),
    "eligible: " + ([.[] | select(.status == "eligible") | "#" + (.number|tostring)] | join(" ")),
    "merged-open: " + ([.[] | select(.status == "merged-open") | "#" + (.number|tostring)] | join(" ")),
    "in-review: " + ([.[] | select(.status == "pr-open") | "#" + (.number|tostring) + "(" + (.pr | ci) + ")"] | join(" "))
' <<<"$tree"
