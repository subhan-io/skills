#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
cleanup() { status=$?; trap - EXIT; rm -rf "$TMP"; exit "$status"; }
trap cleanup EXIT
REPO="$TMP/repo"; STATE="$TMP/state"
mkdir -p "$REPO/apps/one" "$REPO/apps/both" "$STATE"
git -C "$REPO" init -q
printf '%s\n' '# Claude instructions' > "$REPO/CLAUDE.md"
printf '%s\n' '# Nested Claude instructions' > "$REPO/apps/one/CLAUDE.md"
printf '%s\n' '# Both Claude' > "$REPO/apps/both/CLAUDE.md"
printf '%s\n' '# Both Codex' > "$REPO/apps/both/AGENTS.md"
printf '%s\n' 'Return the requested report.' > "$STATE/prompt.md"
printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","additionalProperties":false,"required":["status"],"properties":{"status":{"type":"string","enum":["ok"]}}}' > "$STATE/schema.json"

export RUN_AGENT_CODEX_BIN="$SCRIPT_DIR/test-fixtures/fake-codex.sh"
export RUN_AGENT_CLAUDE_BIN="$SCRIPT_DIR/test-fixtures/fake-claude.sh"
export FAKE_REPORT_JSON='{"status":"ok"}'

pass=0
assert_jq() {
  local json="$1" filter="$2" message="$3"
  jq -e "$filter" <<< "$json" >/dev/null || { echo "not ok - $message" >&2; exit 1; }
  pass=$((pass + 1)); echo "ok $pass - $message"
}

record="$("$SCRIPT_DIR/run-agent.sh" --role fixer --engine codex \
  --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" --cwd "$REPO" \
  --state-dir "$STATE" --out "$STATE/codex.report.json" --timeout 5)"
assert_jq "$record" '.engine == "codex" and .status == "ok" and .reportValid == true and .exitCode == 0' \
  'Codex returns a valid report'
grep -q 'sandbox=workspace-write network=true' "$STATE/fake-codex.args"
test -f "$STATE/codex-state-write-ok"
test ! -e "$REPO/AGENTS.md"
test ! -e "$REPO/apps/one/AGENTS.md"
test ! -L "$REPO/apps/both/AGENTS.md"
pass=$((pass + 1)); echo "ok $pass - Codex writers get network, stateDir access, and temporary instructions"

printf '%s\n' '# Shared instructions' > "$REPO/AGENTS.md"
rm "$REPO/CLAUDE.md"
record="$("$SCRIPT_DIR/run-agent.sh" --role planner --engine claude \
  --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" --cwd "$REPO" \
  --state-dir "$STATE" --out "$STATE/claude.report.json" --timeout 5)"
assert_jq "$record" '.engine == "claude" and .model == "opus" and .status == "ok" and .reportValid == true' \
  'Claude returns a schema-checked report'
grep -Fq 'permission=acceptEdits' "$STATE/fake-claude.args"
grep -Fq 'prompt=Return the requested report.' "$STATE/fake-claude.args"
! grep -Fq '\"$schema\"' "$STATE/fake-claude.args"
pass=$((pass + 1)); echo "ok $pass - Claude receives stdin prompt and compatible inline schema"
test ! -e "$REPO/CLAUDE.md"
pass=$((pass + 1)); echo "ok $pass - reciprocal instruction link is removed after the run"

record="$("$SCRIPT_DIR/run-agent.sh" --role resolver --engine claude \
  --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" --cwd "$REPO" \
  --state-dir "$STATE" --out "$STATE/claude-writer.report.json" --timeout 5)"
assert_jq "$record" '.engine == "claude" and .status == "ok"' 'Claude writer returns a valid report'
grep -Fq 'permission=bypassPermissions' "$STATE/fake-claude.args"
pass=$((pass + 1)); echo "ok $pass - headless Claude writers can execute verification commands"

MAIN_REPO="$TMP/main-repo"; LINKED="$TMP/linked"
git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email test@example.com
git -C "$MAIN_REPO" config user.name Test
printf '%s\n' '# instructions' > "$MAIN_REPO/AGENTS.md"
git -C "$MAIN_REPO" add AGENTS.md
git -C "$MAIN_REPO" commit -qm init
git -C "$MAIN_REPO" worktree add -q -b linked "$LINKED"
FAKE_ARGS_LOG="$STATE/linked-codex.args" FAKE_STATE_DIR="$STATE" \
  "$SCRIPT_DIR/run-agent.sh" --role fixer --engine codex --prompt-file "$STATE/prompt.md" \
  --schema "$STATE/schema.json" --cwd "$LINKED" --state-dir "$STATE" \
  --out "$STATE/linked.report.json" --timeout 5 >/dev/null
git_dir="$(git -C "$LINKED" rev-parse --path-format=absolute --git-dir)"
common_dir="$(git -C "$LINKED" rev-parse --path-format=absolute --git-common-dir)"
grep -Fq "$git_dir" "$STATE/linked-codex.args"
grep -Fq "$common_dir" "$STATE/linked-codex.args"
pass=$((pass + 1)); echo "ok $pass - Codex writers can reach linked-worktree git metadata"

set +e
export FAKE_CODEX_MODE=invalid
record="$("$SCRIPT_DIR/run-agent.sh" --role repo-brief --engine codex \
  --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" --cwd "$REPO" \
  --state-dir "$STATE" --out "$STATE/invalid.report.json" --timeout 5)"
code=$?
unset FAKE_CODEX_MODE
set -e
[ "$code" -eq 65 ]
assert_jq "$record" '.status == "invalid-report" and .reportValid == false and .exitCode == 65' \
  'an invalid report exits 65'

set +e
export FAKE_CODEX_MODE=sleep
record="$("$SCRIPT_DIR/run-agent.sh" --role repo-brief --engine codex \
  --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" --cwd "$REPO" \
  --state-dir "$STATE" --out "$STATE/timeout.report.json" --timeout 1)"
code=$?
unset FAKE_CODEX_MODE
set -e
[ "$code" -eq 124 ]
assert_jq "$record" '.status == "timed-out" and .exitCode == 124' 'a timeout is explicit'

record="$(FAKE_CLAUDE_MODE=rate-limit FAKE_CODEX_MODE=valid "$SCRIPT_DIR/run-agent.sh" \
  --role implementer --index 2 --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" \
  --cwd "$REPO" --state-dir "$STATE" --out "$STATE/failover.report.json" --timeout 5)"
assert_jq "$record" '.requestedEngine == "claude" and .engine == "codex" and .failover == {"from":"claude","reason":"rate-limit"}' \
  'a mechanical Claude rate limit fails over to Codex'

record="$("$SCRIPT_DIR/run-agent.sh" --role repo-brief --engine codex \
  --prompt-file "$STATE/prompt.md" --schema "$STATE/schema.json" --cwd "$REPO" \
  --state-dir "$STATE" --out "$STATE/read-only.report.json" --timeout 5)"
grep -q 'sandbox=read-only network=false' "$STATE/fake-codex.args"
pass=$((pass + 1)); echo "ok $pass - read-only Codex roles keep network disabled"

assert_jq "$(cat "$STATE/engine-ledger.json")" \
  '(.runs | length) == 8 and ([.runs[] | select(.engine == "codex")] | length) == 6 and (.totals.codex > 0) and (.totals.claude > 0)' \
  'the ledger records both engines and recomputes totals'

# shellcheck source=engine-policy.sh
source "$SCRIPT_DIR/engine-policy.sh"
[ "$(engine_for_role implementer 1)" = codex ]
[ "$(engine_for_role implementer 2)" = claude ]
[ "$(engine_for_role planner)" = claude ]
[ "$(engine_for_role rebaser)" = codex ]
pass=$((pass + 1)); echo "ok $pass - balanced role policy is deterministic"

shellcheck -S warning "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/test-fixtures/*.sh
pass=$((pass + 1)); echo "ok $pass - shellcheck passes"
