#!/usr/bin/env bash
# fill-reviewer-prompt.sh <pr> [issue] — assemble the adversarial reviewer prompt (SKILL step 2).
#
# Fills {{PR_NUMBER}}, {{ISSUE_NUMBER}}, {{BRANCH}}, {{SKILL_DIR}}, the repo's verification
# commands and {{REPO_NOTES}} in reviewer-prompt.md, and prints the result. {{SKILL_DIR}} is the
# one that matters for portability: the skill may be installed as a symlink under
# ~/.claude/skills, in the plugin cache, or checked into a repo, so the reviewer can only find
# codex-review.sh if it is handed an absolute path. Never paste the template into an Agent spawn
# by hand — an unfilled {{SKILL_DIR}} silently costs the codex cross-check, and unfilled repo
# notes give you a reviewer that judges the diff against another project's conventions.
#
# The issue number defaults to the branch suffix (agent/issue-<n>), same as everywhere else.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need python3

PR="${1:-}"; [ -n "$PR" ] || die "usage: fill-reviewer-prompt.sh <pr> [issue]"
TEMPLATE="$SKILL_DIR/reviewer-prompt.md"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

BRANCH="$(gh pr view "$PR" --json headRefName --jq .headRefName)"
ISSUE="${2:-$(echo "$BRANCH" | sed "s|^$BRANCH_PREFIX||")}"
case "$ISSUE" in
  ''|*[!0-9]*) die "could not derive an issue number from branch '$BRANCH' — pass it explicitly" ;;
esac

REPO_NOTES="$(read_repo_notes)"

export PR_NUMBER="$PR" ISSUE_NUMBER="$ISSUE" BRANCH SKILL_DIR TEMPLATE REPO_NOTES \
       APP_LABEL APP_DIR INSTALL_CMD TEST_CMD LINT_CMD TYPECHECK_CMD

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
