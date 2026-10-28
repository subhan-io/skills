#!/usr/bin/env bash
# survey.sh — list a project's open issues with the problems an upkeep pass fixes.
#
#   survey.sh --repo <owner/name> --project <number> [--app <name>] [--top-level]
#
# --app keeps issues whose App field is <name>; --top-level keeps issues with no
# parent, which is what the board's per-app views show. Read-only.
#
# Prints one tab-separated line per open issue, longest body first:
#   number  status  type  words  children(closed/total)  flags  title
# Flags:
#   LONG             over 250 words (over 450 for an Epic)
#   CODE             four or more file paths or code spans naming files
#   DONE-OPEN        board Status is Done but the issue is open
#   CHILDREN-CLOSED  has sub-issues and every one is closed
#   PARENT-CLOSED    its parent is closed, so it has dropped off the app views
#   NO-APP, NO-TYPE  the org field is unset, so the issue is missing from views
#   SHIPPED:#n       a merged PR names it with a closing keyword, yet it is open
#                    (often a PR merged into an integration branch, not the default)
#   MENTIONED:#n     a merged PR mentions it without closing it; read the PR to see
#                    whether it did the work (not reported for Epics, whose
#                    children's PRs all mention them)
#   AGENT-NO-DONE    labelled ready-for-agent with no checkbox criteria
set -euo pipefail

repo="" project="" app="" top=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --top-level) top=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 4 ;;
  esac
done
[ -n "$repo" ] && [ -n "$project" ] || { echo "usage: survey.sh --repo <owner/name> --project <number> [--app <name>] [--top-level]" >&2; exit 4; }
owner="${repo%%/*}"

gh api graphql --paginate -H "GraphQL-Features: issue_fields,sub_issues" \
  -f owner="$owner" -F project="$project" -f query='
query($owner:String!,$project:Int!,$endCursor:String){organization(login:$owner){projectV2(number:$project){
  items(first:40,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{
    status:fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}
    content{... on Issue{
      number title state body repository{nameWithOwner}
      issueType{name} parent{number state}
      subIssuesSummary{total completed}
      labels(first:20){nodes{name}}
      issueFieldValues(first:20){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}
      closedByPullRequestsReferences(first:10,includeClosedPrs:true){nodes{number merged}}
      timelineItems(itemTypes:[CROSS_REFERENCED_EVENT],last:20){nodes{... on CrossReferencedEvent{source{... on PullRequest{number merged}}}}}
    }}
  }}
}}}' |
jq -rs --arg repo "$repo" --arg app "$app" --argjson top "$top" '
  [.[].data.organization.projectV2.items.nodes[]
   | .content as $c | select($c.number != null and $c.state == "OPEN" and $c.repository.nameWithOwner == $repo)
   | ($c.issueFieldValues.nodes | map(select(.field.name == "App"))[0].name // "") as $a
   | select($app == "" or $a == $app)
   | select($top == 0 or $c.parent == null)
   | ($c.body // "") as $b
   | ($b | [splits("\\s+")] | map(select(length > 0)) | length) as $w
   | ($c.issueType.name // "") as $t
   | ([$b | scan("`?[\\w./-]*/[\\w.-]+\\.(?:ts|tsx|js|mjs|sql|md|json|ya?ml|sh|py|swift)`?")] | length) as $paths
   | ([$c.closedByPullRequestsReferences.nodes[] | select(.merged) | "#\(.number)"] | unique) as $shipped
   | ([$c.timelineItems.nodes[].source | select(.merged == true) | "#\(.number)"] | unique - $shipped) as $mentions
   | {n: $c.number, w: $w, line: [
       ($c.number | tostring), (.status.name // "-"), (if $t == "" then "-" else $t end), ($w | tostring),
       (if $c.subIssuesSummary.total > 0 then "\($c.subIssuesSummary.completed)/\($c.subIssuesSummary.total)" else "-" end),
       ([ (if $w > (if $t == "Epic" then 450 else 250 end) then "LONG" else empty end),
          (if $paths >= 4 then "CODE" else empty end),
          (if .status.name == "Done" then "DONE-OPEN" else empty end),
          (if $c.subIssuesSummary.total > 0 and $c.subIssuesSummary.completed == $c.subIssuesSummary.total then "CHILDREN-CLOSED" else empty end),
          (if $c.parent.state == "CLOSED" then "PARENT-CLOSED" else empty end),
          (if $a == "" then "NO-APP" else empty end),
          (if $t == "" then "NO-TYPE" else empty end),
          (if ($shipped | length) > 0 then "SHIPPED:" + ($shipped | join(",")) else empty end),
          (if $t != "Epic" and ($mentions | length) > 0 then "MENTIONED:" + ($mentions | join(",")) else empty end),
          (if ([$c.labels.nodes[].name] | index("ready-for-agent")) and ($b | test("- \\[[ x]\\]") | not) then "AGENT-NO-DONE" else empty end)
        ] | if length == 0 then "-" else join(" ") end),
       $c.title
     ] | @tsv}]
  | sort_by(-.w) | .[].line'
