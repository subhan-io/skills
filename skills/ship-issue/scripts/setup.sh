#!/usr/bin/env bash
# setup.sh — everything step 1 needs, in one call: resolve the issue, detect the repo's
# conventions, and create a fresh worktree branched off the CURRENT tip of the default branch.
#
#   setup.sh <issue-url-or-number> [--dry-run]
#
# Emits a JSON blob: issue, repo, baseBranch, branch, worktree, detected commands, warnings.
# Repo-agnostic by detection, not by configuration — there is no env file to write first.
set -euo pipefail
source "$(dirname "$0")/common.sh"

RAW="${1:-}"; shift || true
[ -n "$RAW" ] || die "usage: setup.sh <issue-url-or-number> [--dry-run]"
DRY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=true ;;
    *) die "unknown option: $arg" ;;
  esac
done

ISSUE="$(parse_issue "$RAW")"
SLUG="$(repo_slug)"
ROOT="$(main_repo_root)"
BASE="$(default_branch)"
BRANCH="ship/issue-$ISSUE"
WT="$ROOT/.claude/worktrees/ship-issue-$ISSUE"
WARN=()

# The issue must exist and be open — planning a closed issue is almost always a stale link.
issue_json=$(gh issue view "$ISSUE" --json number,title,body,state,labels,url) \
  || die "cannot read issue #$ISSUE in $SLUG"
if [ "$(echo "$issue_json" | jq -r .state)" != "OPEN" ]; then
  WARN+=("issue #$ISSUE is not OPEN — confirm it is still the right target")
fi

# Detected verification commands. Read what the repo actually declares; a `test` script that
# means WATCH mode will hang an agent until it times out, so prefer an explicit non-watch
# script when the repo offers one.
detect_cmds() {
  local pj="$ROOT/package.json" pm="npm run"
  if [ -f "$pj" ]; then
    [ -f "$ROOT/pnpm-lock.yaml" ] && pm="pnpm"
    [ -f "$ROOT/yarn.lock" ] && pm="yarn"
    [ -f "$ROOT/bun.lockb" ] && pm="bun run"
    has() { jq -e --arg s "$1" '.scripts[$s] // empty' "$pj" >/dev/null 2>&1; }
    # Prefer an explicitly non-watch script over bare `test`: a `test` that means watch mode
    # will hang an agent until it times out, and it reports as neither pass nor fail.
    local test_s=""
    for c in test:run test:ci test; do has "$c" && { test_s="$c"; break; }; done
    # Watch mode is reported through the JSON, not a shell variable: detect_cmds runs in a
    # command substitution, so anything it assigns dies with the subshell.
    local watch="" body=""
    if [ -n "$test_s" ]; then
      body="$(jq -r --arg s "$test_s" '.scripts[$s]' "$pj")"
      case "$body" in
        *--watch|*--watch\ *|*nodemon*|*"karma start"*) watch="$test_s: $body" ;;
        *vitest*) case "$body" in *"vitest run"*|*--run*) ;; *) watch="$test_s: $body" ;; esac ;;
      esac
    fi
    local tc_s=""
    for c in typecheck type-check tsc; do has "$c" && { tc_s="$c"; break; }; done
    local lint_s=""
    for c in lint lint:ci eslint; do has "$c" && { lint_s="$c"; break; }; done
    jq -n --arg pm "$pm" --arg t "$test_s" --arg tc "$tc_s" --arg l "$lint_s" --arg w "$watch" \
      '{ecosystem:"node", install:($pm + " install"),
        test:   (if $t  == "" then null else $pm + " " + $t  end),
        typecheck:(if $tc == "" then null else $pm + " " + $tc end),
        lint:   (if $l  == "" then null else $pm + " " + $l  end),
        watchSuspect: (if $w == "" then null else $w end)}'
  elif [ -f "$ROOT/Cargo.toml" ]; then
    jq -n '{ecosystem:"rust", install:"cargo fetch", test:"cargo test", typecheck:"cargo check", lint:"cargo clippy -- -D warnings"}'
  elif [ -f "$ROOT/go.mod" ]; then
    jq -n '{ecosystem:"go", install:"go mod download", test:"go test ./...", typecheck:"go build ./...", lint:null}'
  elif [ -f "$ROOT/pyproject.toml" ]; then
    jq -n '{ecosystem:"python", install:null, test:"pytest", typecheck:null, lint:null}'
  else
    jq -n '{ecosystem:"unknown", install:null, test:null, typecheck:null, lint:null}'
  fi
}
CMDS="$(detect_cmds)"
if [ "$(echo "$CMDS" | jq -r .ecosystem)" = "unknown" ]; then
  WARN+=("could not detect a toolchain — ask the user how to test before implementing")
fi
if [ "$(echo "$CMDS" | jq -r '.test // "null"')" = "null" ]; then
  WARN+=("no test command detected — ask rather than assuming the repo is untested")
fi
_watch="$(echo "$CMDS" | jq -r '.watchSuspect // ""')"
if [ -n "$_watch" ]; then
  WARN+=("test script looks like WATCH mode ($_watch) — it will hang, not fail. Find the non-watch invocation before implementing")
fi

# Has the codex connector ever reviewed here? If not, the review step will hang on a bot that
# is not installed, so it is worth knowing up front rather than after a 15-minute timeout.
codex_seen=$(gh api "repos/$SLUG/pulls/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "chatgpt-codex-connector[bot]")] | length' 2>/dev/null || echo 0)
[ "${codex_seen:-0}" -eq 0 ] \
  && WARN+=("no codex review comments found in $SLUG — the Codex GitHub app may not be installed; the review step will time out")

# Worktrees live under .claude/worktrees/; committing one is never intended.
if ! git -C "$ROOT" check-ignore -q .claude/worktrees 2>/dev/null; then
  WARN+=(".claude/worktrees/ is not gitignored — add it before creating worktrees")
fi

if [ "$DRY" = false ]; then
  git -C "$ROOT" fetch origin --quiet
  git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$BASE" \
    || die "origin/$BASE not found after fetch"
  if [ -d "$WT" ]; then
    # Never reset existing work — an existing worktree means a previous run, and whether to
    # build on it or discard it is a decision for the human, not a side effect of setup.
    dirty=$(git -C "$WT" status --porcelain | head -1)
    WARN+=("worktree already exists at $WT${dirty:+ (dirty)} — inspect it before reusing")
  else
    mkdir -p "$ROOT/.claude/worktrees"
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$ROOT" worktree add "$WT" "$BRANCH" --quiet
      WARN+=("branch $BRANCH already existed — reused it instead of branching from origin/$BASE")
    else
      git -C "$ROOT" worktree add "$WT" -b "$BRANCH" "origin/$BASE" --quiet
    fi
  fi
fi

jq -n --argjson issue "$issue_json" --arg slug "$SLUG" --arg base "$BASE" \
      --arg branch "$BRANCH" --arg wt "$WT" --argjson cmds "$CMDS" \
      --argjson dry "$DRY" --args '
  {repo:$slug, baseBranch:$base, branch:$branch, worktree:$wt, dryRun:$dry,
   issue:{number:$issue.number, title:$issue.title, url:$issue.url,
          state:$issue.state, labels:($issue.labels|map(.name))},
   commands:$cmds, warnings:$ARGS.positional}' "${WARN[@]+"${WARN[@]}"}"
