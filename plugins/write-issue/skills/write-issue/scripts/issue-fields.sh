#!/usr/bin/env bash
# issue-fields.sh — set an issue's board fields after `gh issue create`, then read
# them back.
#
#   issue-fields.sh --repo <owner/name> --project <number> --issue <n>
#                   [--type <name>] [--app <name>] [--execution <name>]
#                   [--priority <name>] [--size <name>] [--status <name>]
#                   [--parent <n>]
#
# Type, App, Execution and Priority are org-level issue fields: a new issue has
# none of them, and a sub-issue does not inherit App from its parent. Status and
# Size are fields of the org project. Every ID is looked up by name at run time,
# so a renamed option fails loudly instead of silently setting the wrong value.
# The issue is added to the project if it is not on it yet. --parent attaches the
# issue as a native sub-issue and refuses to move it from a different parent.
#
# Prints the fields read back, one line, e.g.
#   #905 type=Feature app=content execution=Agent priority=High parent=#622 status=Backlog size=M
# and exits:
#   0  every requested value reads back as requested
#   1  a mutation failed or a value did not stick (details on stderr)
#   4  bad arguments, or a name with no matching option
set -euo pipefail

repo="" project="" issue=""
type="" app="" execution="" priority="" size="" status="" parent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --execution) execution="$2"; shift 2 ;;
    --priority) priority="$2"; shift 2 ;;
    --size) size="$2"; shift 2 ;;
    --status) status="$2"; shift 2 ;;
    --parent) parent="${2#\#}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 4 ;;
  esac
done
issue="${issue#\#}"
if [ -z "$repo" ] || [ -z "$project" ] || [ -z "$issue" ]; then
  echo "usage: issue-fields.sh --repo <owner/name> --project <number> --issue <n> [field options]" >&2
  exit 4
fi
owner="${repo%%/*}" name="${repo#*/}"

gql() { gh api graphql -H "GraphQL-Features: issue_fields,sub_issues" "$@"; }

meta="$(gql -f owner="$owner" -f name="$name" -F issue="$issue" -F project="$project" -f query='
query($owner:String!,$name:String!,$issue:Int!,$project:Int!){
  organization(login:$owner){
    issueTypes(first:50){nodes{id name}}
    issueFields(first:50){nodes{... on IssueFieldSingleSelect{id name options{id name}}}}
    projectV2(number:$project){id fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name}}}}}
  }
  repository(owner:$owner,name:$name){issue(number:$issue){id}}
}')"
issue_id="$(jq -r '.data.repository.issue.id // empty' <<<"$meta")"
project_id="$(jq -r '.data.organization.projectV2.id // empty' <<<"$meta")"
[ -n "$issue_id" ] || { echo "no issue #$issue in $repo" >&2; exit 4; }
[ -n "$project_id" ] || { echo "no project $project in org $owner" >&2; exit 4; }

lookup() {  # lookup <jq path to nodes> <field name> <option name>: prints field-id option-id
  local ids
  ids="$(jq -r --arg f "$2" --arg o "$3" "$1"' | map(select(.name == $f))[0] // empty
    | [.id, ((.options // []) | map(select((.name | ascii_downcase) == ($o | ascii_downcase)))[0].id // "")] | @tsv' <<<"$meta")"
  if [ -z "$ids" ] || [ -z "$(cut -f2 <<<"$ids")" ]; then
    echo "no option '$3' for field '$2'" >&2; exit 4
  fi
  echo "$ids"
}

failed=0
run() {  # run <label> <gh api graphql args...>: report a failed mutation, keep going
  local label="$1" out; shift
  if ! out="$(gql "$@" 2>&1)" || jq -e '.errors' <<<"$out" >/dev/null 2>&1; then
    echo "$label failed: $out" >&2; failed=1
  fi
}

if [ -n "$type" ]; then
  type_id="$(jq -r --arg t "$type" '.data.organization.issueTypes.nodes | map(select((.name | ascii_downcase) == ($t | ascii_downcase)))[0].id // empty' <<<"$meta")"
  [ -n "$type_id" ] || { echo "no issue type '$type'" >&2; exit 4; }
  run type -f i="$issue_id" -f t="$type_id" -f query='mutation($i:ID!,$t:ID!){updateIssueIssueType(input:{issueId:$i,issueTypeId:$t}){issue{id}}}'
fi

for pair in "App:$app" "Execution:$execution" "Priority:$priority"; do
  field="${pair%%:*}" value="${pair#*:}"
  [ -n "$value" ] || continue
  ids="$(lookup '.data.organization.issueFields.nodes' "$field" "$value")" || exit 4
  read -r fid oid <<<"$ids"
  run "$field" -f i="$issue_id" -f f="$fid" -f o="$oid" -f query='mutation($i:ID!,$f:ID!,$o:ID!){setIssueFieldValue(input:{issueId:$i,issueFields:[{fieldId:$f,singleSelectOptionId:$o}]}){clientMutationId}}'
done

if [ -n "$parent" ]; then
  current="$(gql -f owner="$owner" -f name="$name" -F n="$issue" -f query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){issue(number:$n){parent{number}}}}' -q '.data.repository.issue.parent.number // empty')"
  if [ -n "$current" ] && [ "$current" != "$parent" ]; then
    echo "#$issue already has parent #$current; not moving it to #$parent" >&2; failed=1
  elif [ -z "$current" ]; then
    parent_id="$(gql -f owner="$owner" -f name="$name" -F n="$parent" -f query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){issue(number:$n){id}}}' -q '.data.repository.issue.id // empty')"
    [ -n "$parent_id" ] || { echo "no parent issue #$parent" >&2; exit 4; }
    run parent -f p="$parent_id" -f c="$issue_id" -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{id}}}'
  fi
fi

if [ -n "$status" ] || [ -n "$size" ]; then
  item_id="$(gql -f p="$project_id" -f c="$issue_id" -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' -q '.data.addProjectV2ItemById.item.id // empty')"
  [ -n "$item_id" ] || { echo "could not add #$issue to project $project" >&2; exit 1; }
  for pair in "Status:$status" "Size:$size"; do
    field="${pair%%:*}" value="${pair#*:}"
    [ -n "$value" ] || continue
    ids="$(lookup '.data.organization.projectV2.fields.nodes' "$field" "$value")" || exit 4
    read -r fid oid <<<"$ids"
    run "$field" -f p="$project_id" -f i="$item_id" -f f="$fid" -f o="$oid" -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}'
  done
fi

# Read everything back from GitHub rather than trusting the mutation responses.
back="$(gql -f owner="$owner" -f name="$name" -F n="$issue" -f query='
query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){issue(number:$n){
  issueType{name} parent{number}
  issueFieldValues(first:20){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}
  projectItems(first:10){nodes{project{number} status:fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}} size:fieldValueByName(name:"Size"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}
}}}')"
read_field() { jq -r --arg f "$1" '.data.repository.issue.issueFieldValues.nodes | map(select(.field.name == $f))[0].name // "-"' <<<"$back"; }
got_type="$(jq -r '.data.repository.issue.issueType.name // "-"' <<<"$back")"
got_parent="$(jq -r '.data.repository.issue.parent.number // "-"' <<<"$back")"
got_status="$(jq -r --argjson p "$project" '.data.repository.issue.projectItems.nodes | map(select(.project.number == $p))[0].status.name // "-"' <<<"$back")"
got_size="$(jq -r --argjson p "$project" '.data.repository.issue.projectItems.nodes | map(select(.project.number == $p))[0].size.name // "-"' <<<"$back")"
got_app="$(read_field App)" got_execution="$(read_field Execution)" got_priority="$(read_field Priority)"

echo "#$issue type=$got_type app=$got_app execution=$got_execution priority=$got_priority parent=$([ "$got_parent" = - ] && echo - || echo "#$got_parent") status=$got_status size=$got_size"

check() {  # check <field> <wanted> <got>
  if [ -n "$2" ] && [ "$(tr '[:upper:]' '[:lower:]' <<<"$2")" != "$(tr '[:upper:]' '[:lower:]' <<<"$3")" ]; then
    echo "$1 reads back '$3', wanted '$2'" >&2; failed=1
  fi
}
check type "$type" "$got_type"; check app "$app" "$got_app"; check execution "$execution" "$got_execution"
check priority "$priority" "$got_priority"; check parent "$parent" "$got_parent"
check status "$status" "$got_status"; check size "$size" "$got_size"
exit "$failed"
