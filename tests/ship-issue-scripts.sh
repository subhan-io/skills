#!/usr/bin/env bash
# Fixture tests for the ship-issue ledger, report and review scripts. Runs
# against a throwaway HOME and ledger, with stub Codex and Claude binaries.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scripts="$root/plugins/ship-issue/skills/ship-issue/scripts"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" SHIP_ISSUE_LEDGER="$tmp/ledger.jsonl"
mkdir -p "$HOME"
fails=0
check() {  # check <name> <command...>: the command must succeed
  local name="$1"; shift
  if "$@" >/dev/null; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/widgets.git

# ledger.sh: repo comes from the git origin, not the argument.
run="$("$scripts/ledger.sh" event=run-start issue=7 repo=old-owner/widgets tier=standard cwd="$repo")"
check "run-start records origin repo" \
  jq -e -s --arg r "$run" 'map(select(.run == $r and .event == "run-start"))[0].repo == "acme/widgets"' "$SHIP_ISSUE_LEDGER"

# ledger.sh: plan-approved is logged once per run.
"$scripts/ledger.sh" event=phase phase=plan-approved run="$run" issue=7
"$scripts/ledger.sh" event=phase phase=plan-approved run="$run" issue=7 2>/dev/null
check "plan-approved logged once" \
  jq -e -s --arg r "$run" '[.[] | select(.run == $r and .phase == "plan-approved")] | length == 1' "$SHIP_ISSUE_LEDGER"

# review.sh against stub reviewers.
stub="$tmp/stub"; mkdir -p "$stub"
cat >"$stub/limit.mjs" <<'EOF'
console.log("[codex] Codex error: You've hit your usage limit. Upgrade or try again at 6:58 AM. [codex] Turn failed.");
console.log("# Codex Adversarial Review\nCodex did not return valid structured JSON.");
EOF
cat >"$stub/ok.mjs" <<'EOF'
console.log("[high] src/a.ts:3 — off by one");
EOF
cat >"$stub/broken.mjs" <<'EOF'
console.log("[codex] Turn failed.");
process.exit(1);
EOF
cat >"$stub/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"result","is_error":false,"result":"src/a.ts:3 — off by one","modelUsage":{"claude-opus-5-5":{"cacheReadInputTokens":1000,"cacheCreationInputTokens":200,"outputTokens":30}}}'
EOF
chmod +x "$stub/claude"
export SHIP_ISSUE_CLAUDE_BIN="$stub/claude"
review() { (cd "$repo" && SHIP_ISSUE_CODEX_COMPANION="$stub/$1" \
  "$scripts/review.sh" --run "$run" --issue 7 --round "$2" --base origin/main --focus "Issue #7"); }

out="$(review limit.mjs 1)"
check "usage limit falls back to Claude" grep -q "^# Claude code review (fallback: Codex You've hit your usage limit" <<<"$out"
check "fallback round settles as claude" \
  jq -e -s --arg r "$run" '[.[] | select(.run == $r and .phase == "review-settled" and .round == 1)][0]
         | .reviewer == "claude" and .reviewUsage["claude-opus-5-5"].cacheRead == 1000' "$SHIP_ISSUE_LEDGER"

out="$(review ok.mjs 2)"
check "codex review prints its findings" grep -q "off by one" <<<"$out"
check "codex round settles as codex" \
  jq -e -s --arg r "$run" '[.[] | select(.run == $r and .phase == "review-settled" and .round == 2)][0].reviewer == "codex"' "$SHIP_ISSUE_LEDGER"

set +e; review broken.mjs 3 >/dev/null 2>&1; status=$?; set -e
check "failed codex review exits 1" test "$status" -eq 1
check "failed round does not settle" \
  jq -e -s --arg r "$run" '[.[] | select(.run == $r and .phase == "review-settled" and .round == 3)] | length == 0' "$SHIP_ISSUE_LEDGER"

# usage-report.sh: a resumed run's last run-end is its outcome; fallback usage counts.
"$scripts/ledger.sh" event=run-end run="$run" issue=7 outcome=stopped pr=1 reviewRounds=0
"$scripts/ledger.sh" event=run-end run="$run" issue=7 outcome=merged pr=1 reviewRounds=2
report="$("$scripts/usage-report.sh" --run "$run" --json)"
check "resumed run reports its last outcome" jq -e '.[0].outcome == "merged"' <<<"$report"
check "fallback review usage joins the totals" \
  jq -e '.[0].claude.cache_read == 1000 and .[0].claude.models["claude-opus-5-5(review)"] == 1' <<<"$report"
check "text report lists reviewers" grep -q "claude,codex" <<<"$("$scripts/usage-report.sh" --run "$run")"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
