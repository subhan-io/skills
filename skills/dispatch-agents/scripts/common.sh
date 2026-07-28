# Shared config for dispatch-agents scripts.
#
# The skill installs once per machine but runs against whichever repo you invoke it in, so
# nothing here may be hardcoded to a single project. Precedence, lowest to highest:
#
#   1. the defaults below (tuned for subhan-io/subhanio-platform, the pipeline's first user)
#   2. <repo-root>/.claude/dispatch-agents.env, if present — the per-repo config file
#   3. environment variables already set when the script is invoked
#
# The env file is plain shell (`APP_LABEL=my-app`) and is sourced from the *main* repo root
# even when a script runs inside a linked worktree. See the skill README for a template.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"; }
need gh
need jq
need git

# Main repo root even when invoked from inside a linked worktree
main_repo_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir)" || die "not in a git repo"
  dirname "$common"
}

# Per-repo config. Sourced ahead of the defaults so the file beats them — but a variable the
# caller set explicitly (`APP_LABEL=other ./tick-state.sh`) beats the file, so a one-off
# override still works in a repo that has a config file. Hence the save/restore around the
# source: plain `VAR=value` lines in the file would otherwise clobber the caller's value.
DISPATCH_VARS="APP_LABEL READY_LABEL CLAIM_LABEL REVIEW_LABEL PREVIEW_LABEL CONFLICT_LABEL
  BRANCH_PREFIX BASE_BRANCH TRACKING_ISSUE MAX_ATTEMPTS
  CODEX_BOT CODEX_TRIGGER CODEX_SETTLE_SECONDS CODEX_TIMEOUT_SECONDS CODEX_POLL_SECONDS"
_dispatch_cfg="$(main_repo_root 2>/dev/null || echo "")/.claude/dispatch-agents.env"
if [ -f "$_dispatch_cfg" ]; then
  for _v in $DISPATCH_VARS; do eval "_pre_$_v=\${$_v-}"; done
  # shellcheck disable=SC1090
  . "$_dispatch_cfg"
  for _v in $DISPATCH_VARS; do
    eval "[ -n \"\${_pre_$_v}\" ] && $_v=\${_pre_$_v}" || true
  done
fi

: "${APP_LABEL:=resume-evaluator}"
: "${READY_LABEL:=ready-for-agent}"
: "${CLAIM_LABEL:=agent-in-progress}"
: "${REVIEW_LABEL:=agent:ready-for-review}"
: "${PREVIEW_LABEL:=deploy-preview:resume-evaluator}"
: "${CONFLICT_LABEL:=agent:merge-conflict}"
: "${BRANCH_PREFIX:=agent/issue-}"
: "${BASE_BRANCH:=master}"
: "${TRACKING_ISSUE:=220}"
: "${MAX_ATTEMPTS:=2}"

# Repo slug (owner/name) for gh api calls
repo_slug() { gh repo view --json nameWithOwner --jq .nameWithOwner; }
