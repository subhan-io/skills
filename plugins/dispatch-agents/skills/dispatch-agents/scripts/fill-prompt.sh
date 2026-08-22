#!/usr/bin/env bash
# fill-prompt.sh <issue> — assemble the implementer prompt (SKILL step 4.2).
# Fetches the issue, builds the sibling snapshot (in-flight agent PR issues + their
# files-claim blocks), and fills every {{PLACEHOLDER}} in implementer-prompt.md. Prints to stdout.
#
# The template carries only generic engineering discipline; everything repo-specific arrives
# through the four command vars, {{APP_DIR}}, and {{REPO_NOTES}} (the repo's own operating
# manual, injected verbatim). A missing repo-notes file is fatal here, not papered over.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need python3

N="${1:-}"; [ -n "$N" ] || die "usage: fill-prompt.sh <issue-number>"
TEMPLATE="$SKILL_DIR/implementer-prompt.md"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
SLUG="$(repo_slug)"

issue_json=$(gh issue view "$N" --json title,body)

# Sibling snapshot: every open agent PR (except this issue's) + every claimed open issue,
# with the latest files-claim block from each sibling issue's comments.
siblings=""
sibling_issues=$(
  {
    gh pr list --state open --json headRefName --limit 100 \
      | jq -r --arg p "$BRANCH_PREFIX" '.[] | select(.headRefName|startswith($p)) | .headRefName | ltrimstr($p)'
    gh issue list --label "$CLAIM_LABEL" --label "$APP_LABEL" --state open --json number --jq '.[].number'
  } | sort -un | grep -v "^${N}$" || true
)
for s in $sibling_issues; do
  title=$(gh issue view "$s" --json title --jq .title 2>/dev/null || echo "(unknown)")
  claim=$(gh api "repos/$SLUG/issues/$s/comments" --paginate \
    --jq '.[] | select(.body | contains("```json files-claim")) | .body' 2>/dev/null \
    | tail -1 \
    | awk '/```json files-claim/{f=1;next} /```/{if(f)exit} f' \
    | jq -c '.' 2>/dev/null || echo "")
  siblings+="- #$s $title — branch \`${BRANCH_PREFIX}${s}\` — claimed files: ${claim:-none posted yet}"$'\n'
done
[ -n "$siblings" ] || siblings="(none in flight)"

REPO_NOTES="$(read_repo_notes)"

export ISSUE_NUMBER="$N" \
       ISSUE_TITLE="$(echo "$issue_json" | jq -r .title)" \
       ISSUE_BODY="$(echo "$issue_json" | jq -r '.body // ""')" \
       BRANCH="${BRANCH_PREFIX}${N}" \
       SIBLINGS="$siblings" \
       REPO_NOTES \
       APP_LABEL APP_DIR TRACKING_ISSUE PREVIEW_LABEL BASE_BRANCH TEMPLATE \
       INSTALL_CMD TEST_CMD LINT_CMD TYPECHECK_CMD

python3 - <<'PY'
import os, re, sys
text = open(os.environ["TEMPLATE"]).read()
def sub(m):
    key = m.group(1)
    if key not in os.environ:
        sys.exit(f"unfilled placeholder: {{{{{key}}}}}")
    return os.environ[key]
sys.stdout.write(re.sub(r"\{\{([A-Z_]+)\}\}", sub, text))
PY
