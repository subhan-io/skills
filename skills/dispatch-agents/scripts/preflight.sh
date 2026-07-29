#!/usr/bin/env bash
# preflight.sh — "is this repo ready for a tick?", answered mechanically.
#
# Every check here corresponds to a way a tick fails *silently* rather than loudly: a missing
# app label makes every issue invisible, a missing repo-notes file makes agents invent their own
# database procedure, an un-ignored .claude/worktrees/ puts eight agent checkouts in the next
# diff. Cheaper to fail here than to discover it three spawned agents later.
#
# FAIL = the tick will misbehave; fix before dispatching. WARN = degraded but documented
# fallbacks exist (SKILL.md names each one). Exit 0 if no FAIL, 1 otherwise.
#
#   preflight.sh            # full checklist
#   preflight.sh --quiet    # only WARN/FAIL lines
set -euo pipefail
source "$(dirname "$0")/common.sh"

QUIET=false
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=true ;;
    *) die "usage: preflight.sh [--quiet]" ;;
  esac
done

# Codex settings live in codex-review.sh (SKILL.md documents them there); mirror the two
# defaults preflight needs so this script never depends on that one having run.
: "${CODEX_BOT:=chatgpt-codex-connector[bot]}"
: "${CODEX_TIMEOUT_SECONDS:=900}"

fails=0; warns=0
pass() { [ "$QUIET" = true ] || printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

ROOT="$(main_repo_root)"
echo "dispatch-agents preflight — $ROOT"
echo

# --- Tooling ---------------------------------------------------------------------------------
# common.sh already hard-requires gh/jq/git at source time (so a missing one dies before this
# checklist prints — that's still a clean, named failure). python3 is only needed by the fill
# and validate scripts, which is late enough to be worth catching here.
for t in gh jq git python3; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t on PATH"; else fail "$t not on PATH"; fi
done
if gh auth status >/dev/null 2>&1; then
  pass "gh authenticated"
else
  fail "gh not authenticated — run: gh auth login"
fi

SLUG="$(repo_slug 2>/dev/null || echo "")"
if [ -n "$SLUG" ]; then pass "repo: $SLUG"; else fail "could not resolve the repo via gh (no remote, or no access)"; fi

# --- Config file -----------------------------------------------------------------------------
# Hard fail, per SKILL.md: without it every value below is a built-in default tuned for another
# project, and a tick would claim issues and push branches under the wrong labels.
if [ -f "$DISPATCH_CFG" ]; then
  pass "config: .claude/dispatch-agents.env"
  # A key common.sh doesn't know is silently inert — exactly the failure preflight exists for.
  # shellcheck disable=SC2086  # deliberate word split: one known key per line for grep -f
  unknown=$( { grep -oE '^[[:space:]]*(export )?[A-Za-z_][A-Za-z0-9_]*=' "$DISPATCH_CFG" \
      | sed -E 's/^[[:space:]]*(export )?//; s/=$//' | sort -u \
      | grep -Fxv -f <(printf '%s\n' $DISPATCH_VARS) || true; } | paste -sd' ' -)
  [ -z "$unknown" ] || warn "config sets keys the skill doesn't read (typo?): $unknown"
else
  fail "config missing: .claude/dispatch-agents.env — every value below is a built-in default
      belonging to another repo. See 'Onboarding a repo' in the skill's SKILL.md."
fi

[ "$QUIET" = true ] || cat <<EOF

      resolved config
        APP_LABEL=$APP_LABEL   APP_DIR=$APP_DIR   BASE_BRANCH=$BASE_BRANCH   TRACKING_ISSUE=$TRACKING_ISSUE
        labels: $READY_LABEL / $CLAIM_LABEL / $REVIEW_LABEL / $PREVIEW_LABEL / $CONFLICT_LABEL
        install:   $INSTALL_CMD
        test:      $TEST_CMD
        typecheck: $TYPECHECK_CMD
        lint:      $LINT_CMD

EOF

# --- Kill switch -----------------------------------------------------------------------------
if [ -f "$ROOT/.claude/dispatch-agents.STOP" ]; then
  fail "STOP file present: .claude/dispatch-agents.STOP — the dispatcher will refuse to tick"
else
  pass "no STOP file"
fi

# --- App directory and commands ---------------------------------------------------------------
if [ -d "$ROOT/$APP_DIR" ]; then
  pass "APP_DIR exists: $APP_DIR"
else
  fail "APP_DIR does not exist: $APP_DIR — set APP_DIR in .claude/dispatch-agents.env ('.' for a single-package repo)"
fi
for v in INSTALL_CMD TEST_CMD TYPECHECK_CMD LINT_CMD; do
  eval "val=\"\${$v}\""   # quoted: these are multi-word commands, see common.sh
  if [ -n "$val" ]; then pass "$v set"; else fail "$v is empty — agents would have no gate to run"; fi
done

# --- Base branch ------------------------------------------------------------------------------
# Checked on origin, not locally: claim-issue.sh cuts reservation branches from the *remote*
# head, so a base branch that only exists locally fails at claim time, mid-tick.
if git -C "$ROOT" ls-remote --exit-code origin "refs/heads/$BASE_BRANCH" >/dev/null 2>&1; then
  pass "BASE_BRANCH exists on origin: $BASE_BRANCH"
else
  fail "BASE_BRANCH '$BASE_BRANCH' not found on origin — claims and worktrees would fail at spawn time"
fi

# --- Labels -----------------------------------------------------------------------------------
if [ -n "$SLUG" ]; then
  labels="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  has_label() { printf '%s\n' "$labels" | grep -Fxq "$1"; }
  for l in "$APP_LABEL" "$READY_LABEL" "$CLAIM_LABEL" "$REVIEW_LABEL" "$PREVIEW_LABEL"; do
    if has_label "$l"; then pass "label: $l"; else fail "label missing: $l — run scripts/setup-labels.sh"; fi
  done
  # Both of these have documented fallbacks in SKILL.md (tick-summary-only escalation, and
  # schema-touching-only routing for the opus tier), so their absence degrades rather than breaks.
  for l in "$CONFLICT_LABEL" "$CRITICAL_LABEL"; do
    if has_label "$l"; then pass "label: $l"; else warn "label missing: $l — the pipeline falls back (see SKILL.md); scripts/setup-labels.sh creates it"; fi
  done
  n_ready=$(gh issue list --label "$READY_LABEL" --label "$APP_LABEL" --state open --json number --jq 'length' 2>/dev/null || echo 0)
  if [ "${n_ready:-0}" -gt 0 ]; then
    pass "$n_ready open issue(s) carry both $READY_LABEL and $APP_LABEL"
  else
    warn "no open issue carries both $READY_LABEL and $APP_LABEL — the first tick would dispatch nothing"
  fi
fi

# --- Repo notes -------------------------------------------------------------------------------
NOTES="$(repo_notes_path)"
if [ ! -f "$NOTES" ]; then
  fail "repo notes missing: ${NOTES#"$ROOT"/} — both prompt templates inject this file verbatim;
      without it fill-prompt.sh refuses to run. See 'Onboarding a repo' in SKILL.md."
elif [ ! -s "$NOTES" ]; then
  fail "repo notes empty: ${NOTES#"$ROOT"/} — an empty file reads to an agent as 'this repo has no rules'"
else
  pass "repo notes: ${NOTES#"$ROOT"/} ($(wc -l <"$NOTES" | tr -d ' ') lines)"
fi

# --- Worktrees ignored -------------------------------------------------------------------------
if git -C "$ROOT" check-ignore -q .claude/worktrees 2>/dev/null; then
  pass ".claude/worktrees/ is gitignored"
else
  fail ".claude/worktrees/ is not gitignored — every agent checkout would land in the next diff.
      Add '.claude/worktrees/' to .gitignore."
fi

# --- Tracking issue ----------------------------------------------------------------------------
if [ -n "$SLUG" ]; then
  tstate="$(gh issue view "$TRACKING_ISSUE" --json state --jq .state 2>/dev/null || echo "MISSING")"
  case "$tstate" in
    OPEN)   pass "tracking issue #$TRACKING_ISSUE is open" ;;
    CLOSED) fail "tracking issue #$TRACKING_ISSUE is closed — agents post cross-cutting contracts there" ;;
    *)      fail "tracking issue #$TRACKING_ISSUE not found in $SLUG — set TRACKING_ISSUE in .claude/dispatch-agents.env" ;;
  esac
fi

# --- Codex connector ----------------------------------------------------------------------------
# A warning, not a gate: SKILL step 2 explicitly spawns the reviewer without codex when none
# arrives. But a repo where the connector was never installed will burn a full watch timeout on
# the first green PR before discovering that, so it is worth knowing up front.
if [ -n "$SLUG" ]; then
  seen=$(gh api "repos/$SLUG/pulls/comments?per_page=100" --jq "[.[] | select(.user.login == \"$CODEX_BOT\")] | length" 2>/dev/null || echo 0)
  if [ "${seen:-0}" -gt 0 ]; then
    pass "codex connector seen reviewing here ($seen recent inline comment(s) from $CODEX_BOT)"
  else
    warn "no recent review comments from $CODEX_BOT — if the connector isn't installed, every green PR
      waits out a ${CODEX_TIMEOUT_SECONDS:-900}s watch before the reviewer is spawned without it"
  fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "NOT READY — $fails failure(s), $warns warning(s). Fix the FAILs, then re-run."
  exit 1
fi
echo "READY — 0 failures, $warns warning(s). Start with a dry tick: /dispatch-agents dry"
