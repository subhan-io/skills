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
STATE="$ROOT/.claude/worktrees/ship-issue-$ISSUE.state"
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

# Publishing. The plan explainer is published as a URL so the human can read it from any device
# (this usually runs on a remote box), and a UI chunk captures with Playwright and then has to
# publish its shots — both through pr-media-upload, a separate plugin needing `infisical` and `aws`
# on PATH plus credentials.
# Discovering that at the publish step means the whole capture is wasted, so check it up front
# and let the human decide (install the deps, or accept UI chunks reporting un-capturable).
# Search, don't guess at the depth. The plugin-cache layout nests the skill several levels down
# (plugins/cache/<marketplace>/<plugin>/<hash>/skills/pr-media-upload/upload.sh), so a glob with a
# fixed number of wildcards reports "not installed" for a plugin that is installed and working.
UPLOAD=""
for _p in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/pr-media-upload/upload.sh" \
          "$HOME/.claude/skills/pr-media-upload/upload.sh"; do
  [ -x "$_p" ] && { UPLOAD="$_p"; break; }
done
if [ -z "$UPLOAD" ]; then
  # Only search roots that exist, and swallow the status: under `set -o pipefail` a find that
  # errors on a missing directory takes the whole script down with it.
  _roots=()
  for _r in "$HOME/.claude/plugins" "$HOME/.claude/skills"; do
    [ -d "$_r" ] && _roots+=("$_r")
  done
  if [ ${#_roots[@]} -gt 0 ]; then
    UPLOAD="$(find "${_roots[@]}" -path '*pr-media-upload/upload.sh' \
                -type f -perm -u+x -print 2>/dev/null | head -1 || true)"
  fi
fi
if [ -z "$UPLOAD" ]; then
  WARN+=("pr-media-upload not found — the plan explainer can only be read from its path on this machine, and UI chunks will have nowhere to publish screenshots; install the plugin or expect both")
else
  # uuidgen is not a given on a fresh Debian/Alpine box, and upload.sh calls it to build the
  # object key — missing, it fails AFTER the capture work is done, which is the whole thing this
  # check exists to prevent.
  _missing=()
  for _bin in infisical aws uuidgen; do
    command -v "$_bin" >/dev/null 2>&1 || _missing+=("$_bin")
  done
  [ ${#_missing[@]} -gt 0 ] \
    && WARN+=("pr-media-upload found at $UPLOAD but ${_missing[*]} not on PATH — screenshot publishing will fail after the capture work is already done")
fi

# No check for the `handoff` skill: chunk implementers follow the bundled handoff-prompt.md, and
# only defer to that skill when it happens to be installed. Nothing to warn about either way.

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

  # Run state lives BESIDE the worktree, not inside it. Inside, every file shows as untracked and
  # one `git add -A` commits the plan and the handoffs into the PR diff — the same leak the
  # screenshot harness rules exist to prevent. Here it is under the already-gitignored
  # .claude/worktrees/ path, so neither the main repo nor the worktree can see it.
  mkdir -p "$STATE"

  # A fresh worktree is a fresh checkout: dependencies are not shared with the main one. Left
  # undetected, the planner burns part of its budget discovering this and installing.
  if [ -f "$WT/package.json" ] && [ ! -d "$WT/node_modules" ]; then
    WARN+=("worktree has no node_modules — run '$(echo "$CMDS" | jq -r '.install // "the install command"')' in $WT before planning")
  fi
fi

# The issue usually names its own gate ("`pnpm check` passes" in the acceptance criteria), and in
# a monorepo that command frequently does NOT exist at the root — it lives in the app the issue is
# about. Detection reads the root manifest, so left alone it reports a set of commands that are
# real but beside the point, and the agent verifies the wrong thing. Surface what the issue asked
# for and say where the script actually lives.
#
# Resolve it against the WORKTREE, which is cut from origin/<base>, not against the main checkout,
# which is wherever the human left it and is routinely behind. A script added, moved or removed on
# the base branch would otherwise be reported with the wrong directory — or as missing — and that
# stale answer is what every agent gets told. This runs after worktree creation for that reason.
STATED='[]'
_src="$ROOT"; _src_label="main checkout"
if [ -d "$WT" ]; then _src="$WT"; _src_label="worktree"; fi
if [ -f "$_src/package.json" ]; then
  [ "$_src_label" = "worktree" ] || WARN+=("issue-stated commands were resolved against the $_src_label (no worktree yet) — it may be behind origin/$BASE")
  # Pull every backticked span out of the issue body, then read the command out of the span. The
  # documented monorepo form is `cd apps/foo && pnpm check`, so a pattern anchored on a backtick
  # immediately before the package manager finds nothing at all — silently, which is worse than
  # not looking.
  #
  # Two values come out of each span and they are NOT the same thing:
  #   _pmcmd  — the full command to RUN, arguments and all. `pnpm test --filter web` and
  #             `pnpm test` are different gates; a flag can pick the workspace or turn off watch
  #             mode, so reporting the truncated form lets an agent pass a check it never ran.
  #   _script — just the script name, used ONLY to locate the manifest that declares it.
  _spans=$(echo "$issue_json" | jq -r '.body // ""' | grep -oE '`[^`]+`' | tr -d '`' | sort -u || true)
  while IFS= read -r _span; do
    [ -n "$_span" ] || continue
    # Strip a leading `cd <dir> &&`, keeping the directory as an explicit hint from the author.
    _hint=""; _rest="$_span"
    case "$_span" in
      cd\ *\&\&*)
        _hint=$(printf '%s' "$_span" | sed -E 's/^cd +([^ ]+) +&&.*/\1/')
        _rest=$(printf '%s' "$_span" | sed -E 's/^cd +[^ ]+ +&& *//')
        ;;
    esac
    printf '%s' "$_rest" | grep -qE '^(pnpm|npm|yarn|bun)( run)? [a-zA-Z]' || continue
    _pmcmd="$_rest"                                   # full command, arguments preserved
    _script=$(printf '%s' "$_rest" \
      | sed -E 's/^(pnpm|npm|yarn|bun)( run)? +([a-zA-Z][a-zA-Z0-9:_-]*).*/\3/')
    # An explicit `cd <dir>` from the issue author beats repo-wide discovery: when the root and an
    # app both declare the same script name, searching first resolves to the wrong package and
    # every agent then runs the right script in the wrong place. Validate the hint, do not assume.
    _where=""
    if [ -n "$_hint" ] && [ -f "$_src/$_hint/package.json" ] \
       && jq -e --arg s "$_script" '.scripts[$s] // empty' "$_src/$_hint/package.json" >/dev/null 2>&1; then
      _where="$_hint"
    elif jq -e --arg s "$_script" '.scripts[$s] // empty' "$_src/package.json" >/dev/null 2>&1; then
      _where="."
    else
      _where=$(find "$_src" -maxdepth 3 -name package.json -not -path '*/node_modules/*' \
                 -exec sh -c 'jq -e --arg s "$1" ".scripts[\$s] // empty" "$2" >/dev/null 2>&1' _ "$_script" {} \; \
                 -print 2>/dev/null | head -1 || true)
      _where="${_where:+$(dirname "${_where#"$_src"/}")}"
    fi
    if [ -z "$_where" ] && [ -n "$_hint" ]; then
      WARN+=("issue says to run \`$_pmcmd\` in $_hint but no package.json there declares '$_script' — confirm the command with the user")
      _where="$_hint"
    elif [ -z "$_where" ]; then
      WARN+=("issue names \`$_pmcmd\` but no package.json in the $_src_label declares a '$_script' script — confirm the command with the user")
    elif [ "$_where" != "." ]; then
      WARN+=("issue names \`$_pmcmd\` but '$_script' is NOT a root script — it lives in $_where; run it as: cd $_where && $_pmcmd")
    fi
    STATED=$(jq -c --arg c "$_pmcmd" --arg w "${_where:-}" \
      '. + [{command:$c, dir:(if $w=="" then null else $w end)}]' <<<"$STATED")
  done <<<"$_spans"
fi

# uploadScript is emitted so the orchestrator can hand implementers the absolute path rather than
# making each one repeat the filesystem search — and get it wrong only after doing the capture.
jq -n --argjson issue "$issue_json" --arg slug "$SLUG" --arg base "$BASE" \
      --arg branch "$BRANCH" --arg wt "$WT" --arg state "$STATE" --argjson cmds "$CMDS" \
      --arg upload "$UPLOAD" --argjson stated "$STATED" --argjson dry "$DRY" --args '
  {repo:$slug, baseBranch:$base, branch:$branch, worktree:$wt, stateDir:$state, dryRun:$dry,
   issue:{number:$issue.number, title:$issue.title, url:$issue.url,
          state:$issue.state, labels:($issue.labels|map(.name))},
   commands:$cmds, issueStatedCommands:$stated,
   uploadScript:(if $upload == "" then null else $upload end),
   warnings:$ARGS.positional}' "${WARN[@]+"${WARN[@]}"}"
