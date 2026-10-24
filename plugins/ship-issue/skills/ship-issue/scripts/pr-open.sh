#!/usr/bin/env bash
# pr-open.sh — push the run's branch and open its PR, only when the branch is ready.
#
#   pr-open.sh --issue <n|adhoc-slug> --base <branch> --title "<title>" --body-file <file>
#
# Run from the repo, on the run's branch. It refuses, and opens nothing, when:
#   - the tree has uncommitted changes: the PR must hold exactly the commit the
#     evidence gate rendered, so a capture harness has to be gone first;
#   - the branch is the base, or HEAD is detached;
#   - for a numbered issue, the body's first line is not `Closes #<n>`: the epic
#     survey finds a sub-issue's PR by it;
#   - the issue is a sub-issue of an epic that has an integration branch
#     (`epic/<parent>` on origin) and --base is not that branch;
#   - --base does not exist on origin.
# A branch that already has an open PR is pushed, and that PR is reported.
#
# Prints one line and exits:
#   0  opened <url>  |  exists <url>
#   1  the push or `gh pr create` failed (its output is on stderr)
#   3  refused <reason>
#   4  bad arguments
set -euo pipefail

issue="" base="" title="" body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --body-file) body="$2"; shift 2 ;;
    *) echo "pr-open.sh: unknown argument $1" >&2; exit 4 ;;
  esac
done
for v in issue base title body; do
  [ -n "${!v}" ] || { echo "pr-open.sh: --${v/body/body-file} is required" >&2; exit 4; }
done
[ -f "$body" ] || { echo "pr-open.sh: no body file at $body" >&2; exit 4; }
refuse() { echo "refused $*"; exit 3; }

dirty="$(git status --porcelain)"
[ -z "$dirty" ] || refuse "uncommitted changes ($(wc -l <<<"$dirty") path(s)): commit them, or remove the capture harness"
branch="$(git symbolic-ref --quiet --short HEAD)" || refuse "HEAD is detached: check out the run's branch"
[ "$branch" != "$base" ] || refuse "on the base branch $base: the run's work belongs on its own branch"

if [[ "$issue" =~ ^[0-9]+$ ]]; then
  first="$(grep -m1 -v '^[[:space:]]*$' "$body" || true)"
  [[ "$first" =~ ^Closes\ \#$issue([^0-9]|$) ]] || refuse "the body's first line must be 'Closes #$issue', got '$first'"
  slug="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  parent="$(gh api graphql -f query="query{repository(owner:\"${slug%%/*}\",name:\"${slug#*/}\"){issue(number:$issue){parent{number}}}}" \
    -q '.data.repository.issue.parent.number // empty' 2>/dev/null || true)"
  if [ -n "$parent" ] && [ "$base" != "epic/$parent" ] \
     && git ls-remote --exit-code --heads origin "epic/$parent" >/dev/null 2>&1; then
    refuse "#$issue is a sub-issue of epic #$parent, which has an integration branch: use --base epic/$parent"
  fi
fi
git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1 || refuse "base $base does not exist on origin"

git push -u origin HEAD >&2 || exit 1
existing="$(gh pr view "$branch" --json url,state -q 'select(.state == "OPEN") | .url' 2>/dev/null || true)"
if [ -n "$existing" ]; then echo "exists $existing"; exit 0; fi
url="$(gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body")" || exit 1
echo "opened $(tail -1 <<<"$url")"
