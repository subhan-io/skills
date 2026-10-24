#!/usr/bin/env bash
# Fixture tests for the ship-issue ledger, report, review, arm, merge and PR
# scripts and the Fable hook. Runs against a throwaway HOME and ledger, with stub
# Codex, Claude and gh binaries.
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

# usage-report.sh: orch_cache_read counts the orchestrator transcript, not its subagents.
repo2="$tmp/repo2"; git init -q "$repo2"
proj="$HOME/.claude/projects/$(echo "$repo2" | sed 's|[/.]|-|g')"
mkdir -p "$proj/orch/subagents"
run2="$("$scripts/ledger.sh" event=run-start issue=8 tier=standard cwd="$repo2" claudeSession=orch.jsonl)"
sleep 1; ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
msg() { printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"claude-sonnet-5-5","usage":{"cache_read_input_tokens":%s}}}\n' "$ts" "$1" "$2"; }
msg m1 300 >"$proj/orch.jsonl"
msg s1 700 >"$proj/orch/subagents/agent-a.jsonl"
sleep 1; "$scripts/ledger.sh" event=run-end run="$run2" issue=8 outcome=pr-open pr=2
report2="$("$scripts/usage-report.sh" --run "$run2" --json)"
check "orchestrator share excludes subagents" \
  jq -e '.[0].claude.cache_read == 1000 and .[0].claude.orch_cache_read == 300' <<<"$report2"
check "text report shows orch%" grep -q "30%" <<<"$("$scripts/usage-report.sh" --run "$run2")"

# arm.sh: a stable arm per run, logged once; forced arms are marked and excluded.
arm1="$("$scripts/arm.sh" --run "$run" --issue 7 --experiment impl)"
arm2="$("$scripts/arm.sh" --run "$run" --issue 7 --experiment impl)"
check "arm is stable for a run" test "$arm1" = "$arm2"
check "arm is logged once" \
  jq -e -s --arg r "$run" '[.[] | select(.run == $r and .phase == "arm")] | length == 1' "$SHIP_ISSUE_LEDGER"
arms_seen="$(for i in $(seq 1 12); do SHIP_ISSUE_LEDGER="$tmp/arms.jsonl" "$scripts/arm.sh" --run "r-$i" --issue 7 --experiment plan; done | sort -u | tr '\n' ' ')"
check "both arms occur across runs" test "$arms_seen" = "delegate inline "
forced="$(EVAL_SHIP_ISSUE_ARM_PLAN=inline "$scripts/arm.sh" --run "$run" --issue 7 --experiment plan)"
check "eval env forces the arm" test "$forced" = inline
check "forced arm is marked" \
  jq -e -s --arg r "$run" '[.[] | select(.run == $r and .experiment == "plan")][0].forced == true' "$SHIP_ISSUE_LEDGER"
check "report lists arms" grep -q "impl:$arm1,plan:inline!" <<<"$("$scripts/usage-report.sh" --run "$run")"
byarm="$("$scripts/usage-report.sh" --since 1970-01-01 --by-arm)"
check "by-arm groups the unforced arm" grep -qE "prod +impl +$arm1 +1 +1" <<<"$byarm"
check "by-arm leaves forced arms out" bash -c '! grep -q "plan" <<<"$0"' "$byarm"

# A stub gh for merge.sh and pr-open.sh: answers from files in $GH_STUB.
GH_STUB="$tmp/gh"; mkdir -p "$GH_STUB/bin"; export GH_STUB
cat >"$GH_STUB/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_STUB/calls"
q=""; args=("$@")
for i in "${!args[@]}"; do [ "${args[$i]}" = "-q" ] && q="${args[$((i + 1))]}"; done
out() { if [ -n "$q" ]; then jq -r "$q" "$GH_STUB/$1"; else cat "$GH_STUB/$1"; fi; }
case "$1 $2" in
  "pr view") if [ -f "$GH_STUB/pr.json" ]; then out pr.json; else exit 1; fi ;;
  "pr checks") cat "$GH_STUB/checks.json" ;;
  "pr merge") [ ! -f "$GH_STUB/merge-fails" ] || { echo "head moved" >&2; exit 1; } ;;
  "pr create") echo "https://github.com/acme/widgets/pull/9" ;;
  "repo view") out repo.json ;;
  "issue close") ;;
  "api graphql") out graphql.json ;;
  *) echo "gh stub: unhandled $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$GH_STUB/bin/gh"
export PATH="$GH_STUB/bin:$PATH"

# merge.sh
merge_run="$("$scripts/ledger.sh" event=run-start issue=11 tier=standard)"
printf '{"defaultBranchRef":{"name":"main"},"nameWithOwner":"acme/widgets"}' >"$GH_STUB/repo.json"
printf '[{"name":"ci","bucket":"pass","link":""}]' >"$GH_STUB/checks.json"
pr_json() {  # pr_json <base> <last commit date>
  printf '{"state":"OPEN","isDraft":false,"baseRefName":"%s","headRefOid":"abc123","commits":[{"committedDate":"%s"}]}' "$1" "$2" >"$GH_STUB/pr.json"
}
merge() { set +e; "$scripts/merge.sh" --repo acme/widgets --pr 5 --run "$merge_run" --issue 11 "$@"; mstatus=$?; set -e; }
pr_json main 2026-01-01T00:00:00Z
merge >"$tmp/out"
check "merge refuses before any review" test "$mstatus" -eq 3
"$scripts/ledger.sh" event=phase phase=review-settled round=1 run="$merge_run" issue=11
pr_json main 2999-01-01T00:00:00Z
merge >"$tmp/out"
check "merge refuses fixes after round 1 without round 2" grep -q "run round 2" "$tmp/out"
merge --round2-skipped "CI fix" >"$tmp/out"
check "round2-skipped lets a non-fix commit merge" grep -q "^merged abc123 base=main closed=no" "$tmp/out"
check "merge pins the green head" grep -q "match-head-commit abc123" "$GH_STUB/calls"
pr_json epic/3 2026-01-01T00:00:00Z
merge >"$tmp/out"
check "merge into an epic branch closes the issue" grep -q "closed=11" "$tmp/out"
printf '[{"name":"ci","bucket":"fail","link":""}]' >"$GH_STUB/checks.json"
merge >"$tmp/out"
check "red CI does not merge" test "$mstatus" -eq 1
printf '[{"name":"ci","bucket":"pass","link":""}]' >"$GH_STUB/checks.json"
touch "$GH_STUB/merge-fails"; merge >"$tmp/out"; rm "$GH_STUB/merge-fails"
check "a failed gh merge is a refusal" test "$mstatus" -eq 3

# pr-open.sh against a local bare origin.
origin="$tmp/origin.git"; git init -q --bare "$origin"
work="$tmp/work"; git init -q -b main "$work"
git -C "$work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$work" branch epic/3
git -C "$work" remote add origin "$origin"; git -C "$work" push -q origin main epic/3
git -C "$work" checkout -q -b feat
printf 'Closes #12\n\nbody\n' >"$tmp/body.md"
printf '{"nameWithOwner":"acme/widgets"}' >"$GH_STUB/repo.json"
printf '{"data":{"repository":{"issue":{"parent":{"number":3}}}}}' >"$GH_STUB/graphql.json"
rm -f "$GH_STUB/pr.json"
open_pr() { (cd "$work" && "$scripts/pr-open.sh" --issue 12 --title t "$@") || true; }
touch "$work/stray"; open_pr --base epic/3 --body-file "$tmp/body.md" >"$tmp/out"; rm "$work/stray"
check "pr-open refuses a dirty tree" grep -q "uncommitted changes" "$tmp/out"
open_pr --base main --body-file "$tmp/body.md" >"$tmp/out"
check "pr-open sends an epic sub-issue to its integration branch" grep -q "use --base epic/3" "$tmp/out"
printf 'Fixes #12\n' >"$tmp/bad.md"
open_pr --base epic/3 --body-file "$tmp/bad.md" >"$tmp/out"
check "pr-open requires Closes #<n> first" grep -q "must be 'Closes #12'" "$tmp/out"
open_pr --base epic/3 --body-file "$tmp/body.md" >"$tmp/out" 2>/dev/null
check "pr-open pushes and opens the PR" grep -q "^opened https://github.com/acme/widgets/pull/9" "$tmp/out"
check "pr-open pushed the branch" git -C "$origin" rev-parse --verify -q refs/heads/feat

# fable-guard.sh
guard="$root/plugins/ship-issue/hooks/fable-guard.sh"
fable() { printf '{"tool_input":%s}' "$1" | "$guard"; }
check "guard denies a Fable subagent" grep -q '"deny"' <<<"$(fable '{"model":"fable"}')"
check "guard denies a Fable thread launch" grep -q '"deny"' <<<"$(fable '{"modelSelection":{"model":"claude-fable-5-1"}}')"
check "guard allows Sonnet" test -z "$(fable '{"model":"sonnet"}')"
mkdir -p "$HOME/.config/ship-issue"; touch "$HOME/.config/ship-issue/allow-fable"
check "allow-fable file lets Fable through" test -z "$(fable '{"model":"fable"}')"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
