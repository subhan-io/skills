# Shared config for dispatch-agents scripts.
#
# The skill installs once per machine but runs against whichever repo you invoke it in, so
# nothing here may be hardcoded to a single project. Precedence, lowest to highest:
#
#   1. the defaults below (tuned for subhan-io/subhanio-platform, the pipeline's first user)
#   2. <repo-root>/.claude/dispatch-agents.env, if present — the per-repo config file
#   3. environment variables already set when the script is invoked
#
# The env file is `KEY=value` lines, read from the *main* repo root even when a script runs
# inside a linked worktree. `scripts/preflight.sh` checks a repo has one and that everything it
# names exists; SKILL.md's "Onboarding a repo" has the template.

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

# Per-repo config. Every knob a repo may set; also the whitelist the loader below honours, so
# a typo'd key is inert rather than clobbering PATH (preflight.sh reports unknown keys).
DISPATCH_VARS="APP_LABEL APP_DIR READY_LABEL CLAIM_LABEL REVIEW_LABEL PREVIEW_LABEL CONFLICT_LABEL
  BRANCH_PREFIX BASE_BRANCH TRACKING_ISSUE MAX_ATTEMPTS
  INSTALL_CMD TEST_CMD LINT_CMD TYPECHECK_CMD REPO_NOTES_FILE
  CODEX_BOT CODEX_TRIGGER CODEX_SETTLE_SECONDS CODEX_TIMEOUT_SECONDS CODEX_POLL_SECONDS"
DISPATCH_CFG="$(main_repo_root 2>/dev/null || echo "")/.claude/dispatch-agents.env"

# The file is PARSED, not sourced. Sourcing it would execute `TEST_CMD=pnpm --dir apps/x test`
# as the *command* `--dir` with a one-shot env var — the values here are commands, and people
# reasonably write them unquoted, so a config file must not double as a shell script. Parsing
# also means a stray line can't run code or export something the pipeline never asked for.
# Precedence: a variable the caller set explicitly (`APP_LABEL=other ./tick-state.sh`) wins over
# the file, so a one-off override still works in a repo that has one.
# shellcheck disable=SC2086  # deliberate: collapse the multi-line list to space-separated
_dispatch_known=" $(echo $DISPATCH_VARS) "
if [ -f "$DISPATCH_CFG" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line#"${_line%%[![:space:]]*}"}"          # ltrim
    case "$_line" in ''|'#'*) continue ;; esac
    _line="${_line#export }"
    case "$_line" in *=*) ;; *) continue ;; esac
    _key="${_line%%=*}"; _val="${_line#*=}"
    case "$_key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$_dispatch_known" in *" $_key "*) ;; *) continue ;; esac
    case "$_val" in
      \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;    # quoted: take it literally
      \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
      *) _val="${_val%%[[:space:]]#*}" ;;               # unquoted: strip a trailing # comment
    esac
    _val="${_val%"${_val##*[![:space:]]}"}"             # rtrim
    if eval "[ -n \"\${$_key-}\" ]"; then continue; fi  # caller env already set it — it wins
    eval "$_key=\$_val"                                 # assignment RHS: no word splitting
  done < "$DISPATCH_CFG"
fi

: "${APP_LABEL:=resume-evaluator}"
: "${READY_LABEL:=ready-for-agent}"
: "${CLAIM_LABEL:=agent-in-progress}"
: "${REVIEW_LABEL:=agent:ready-for-review}"
: "${PREVIEW_LABEL:=deploy-preview:$APP_LABEL}"
: "${CONFLICT_LABEL:=agent:merge-conflict}"
: "${BRANCH_PREFIX:=agent/issue-}"
: "${BASE_BRANCH:=master}"
: "${TRACKING_ISSUE:=220}"
: "${MAX_ATTEMPTS:=2}"

# The app package directory, relative to the main repo root — `.` in a single-package repo.
# Derived from APP_LABEL because that is the monorepo convention these defaults were tuned
# for; any repo that doesn't follow it MUST set APP_DIR explicitly (preflight.sh fails the
# repo if the directory doesn't exist, so a wrong guess here is loud, not silent).
: "${APP_DIR:=apps/$APP_LABEL}"

# The four verification commands, each runnable as-is from a worktree root. They are config,
# not prompt text, because every repo gates on something different: the prompt templates
# carry the discipline (run them from your own worktree, never wrap them in `timeout`), the
# repo says what to run. Anything that isn't one of these four — e2e suites, build, format
# checks — belongs in the repo-notes file, not here.
: "${INSTALL_CMD:=pnpm install --frozen-lockfile}"
: "${TEST_CMD:=pnpm --dir $APP_DIR test}"
: "${LINT_CMD:=pnpm lint --filter=$APP_LABEL -- --max-warnings=0}"
: "${TYPECHECK_CMD:=pnpm typecheck --filter=$APP_LABEL}"

# Per-repo operating manual injected verbatim into both prompt templates as {{REPO_NOTES}}.
# Path is relative to the main repo root. Every repo-specific procedure that used to be
# hardcoded in the templates lives here; there is no default content and no empty fallback —
# fill-prompt.sh and fill-reviewer-prompt.sh hard-fail when it is missing.
: "${REPO_NOTES_FILE:=.claude/dispatch-agents/repo-notes.md}"

# The critical-path label is deliberately NOT configurable: SKILL.md routes the opus tier on
# it by name, and both it and CONFLICT_LABEL have documented fallbacks when absent, so a repo
# that never creates them still ticks. setup-labels.sh/preflight.sh use this constant.
CRITICAL_LABEL="agent-critical-path"

# Repo slug (owner/name) for gh api calls
repo_slug() { gh repo view --json nameWithOwner --jq .nameWithOwner; }

# Absolute path of REPO_NOTES_FILE (relative paths resolve against the *main* repo root, so
# this is stable from inside a linked worktree).
repo_notes_path() {
  case "$REPO_NOTES_FILE" in
    /*) echo "$REPO_NOTES_FILE" ;;
    *)  echo "$(main_repo_root)/$REPO_NOTES_FILE" ;;
  esac
}

# The {{REPO_NOTES}} payload. Missing or empty is a hard error naming the file: a prompt with
# silently-empty repo notes reads as "this repo has no special rules", and the agent then
# invents its own database, screenshot and standards procedures.
read_repo_notes() {
  local p; p="$(repo_notes_path)"
  [ -f "$p" ] || die "repo notes not found: $p
Every dispatched agent reads this file for the repo's database, screenshot, standards and
verification procedures. Create it — see 'Onboarding a repo' in the skill's SKILL.md — or
point REPO_NOTES_FILE at an existing one in .claude/dispatch-agents.env."
  [ -s "$p" ] || die "repo notes file is empty: $p (see 'Onboarding a repo' in SKILL.md)"
  cat "$p"
}
