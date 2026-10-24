#!/usr/bin/env bash
# replay.sh — replay a closed issue through ship-issue's eval mode, and grade the
# result against the PR that actually shipped it.
#
#   replay.sh run   --repo <checkout> --issue <n> [--pr <n>] [--arm impl=inline]
#                   [--arm plan=delegate] [--model sonnet] [--setup "<cmd>"]
#                   [--plugin-dir <dir>] [--max-budget-usd <usd>] [--dry-run]
#   replay.sh grade <replay dir> [--judge-model opus]
#   replay.sh report [--since 2026-10-01]
#
# run: finds the merged PR that shipped the issue (--pr overrides), puts a worktree
#   at the commit before its merge on a branch `eval/<n>-<stamp>`, runs --setup in
#   it, then runs `claude -p` there with "Use the ship-issue skill with: eval afk
#   #<n> base=<sha>". Eval mode (eval.md) reads the issue and publishes nothing:
#   no push, no PR, no comment. The session loads the ship-issue plugin from
#   --plugin-dir (default: this checkout's plugin, so an uncommitted skill change
#   is what runs) and disables the installed copy. --arm pins an experiment's arm
#   through EVAL_SHIP_ISSUE_ARM_<EXPERIMENT>. Everything lands in the replay dir,
#   ~/.local/state/ship-issue/replays/<n>-<stamp>/: meta.json, result.json (the
#   session's cost and usage), handover.md, run.patch and reference.patch.
# grade: asks a judge model to compare run.patch with reference.patch against the
#   issue and the handover, and writes grade.json: criteria met, regressions, and
#   a verdict on the run against the shipped PR.
# report: one row per replay, beside its ledger run's cache reads and review
#   counts from usage-report.sh.
#
# A replay costs what a real run costs. Pick a handful of issues, run each arm
# at least twice, and compare with `report`, not one run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../skills/ship-issue/scripts"
REPLAYS="${SHIP_ISSUE_REPLAYS:-$HOME/.local/state/ship-issue/replays}"
die() { echo "replay.sh: $*" >&2; exit 2; }

cmd_run() {
  local repo="" issue="" pr="" model="sonnet" setup="" plugin_dir="$here/.." budget="" dry=0
  local arms=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      --arm) arms+=("$2"); shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --setup) setup="$2"; shift 2 ;;
      --plugin-dir) plugin_dir="$2"; shift 2 ;;
      --max-budget-usd) budget="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "unknown argument $1" ;;
    esac
  done
  if [ -z "$repo" ] || [ -z "$issue" ]; then die "run needs --repo and --issue"; fi
  case "$model" in *fable*) die "replays run on sonnet or opus; Fable needs the human's explicit request" ;; esac
  repo="$(cd "$repo" && git rev-parse --show-toplevel)"
  plugin_dir="$(cd "$plugin_dir" && pwd)"
  local slug; slug="$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner)"

  if [ -z "$pr" ]; then
    pr="$(gh issue view "$issue" -R "$slug" --json closedByPullRequestsReferences \
            -q '[.closedByPullRequestsReferences[] | .number] | first // empty')"
    [ -n "$pr" ] || pr="$(gh pr list -R "$slug" --state merged --search "\"Closes #$issue\" in:body" \
                            --json number -q 'first | .number // empty')"
    [ -n "$pr" ] || die "no merged PR found for #$issue: pass --pr"
  fi
  local info merge base_ref
  info="$(gh pr view "$pr" -R "$slug" --json mergeCommit,baseRefName,state,title)"
  [ "$(jq -r .state <<<"$info")" = "MERGED" ] || die "PR #$pr is not merged"
  merge="$(jq -r .mergeCommit.oid <<<"$info")"; base_ref="$(jq -r .baseRefName <<<"$info")"
  git -C "$repo" fetch -q origin "$merge" 2>/dev/null || git -C "$repo" fetch -q origin
  local base; base="$(git -C "$repo" rev-parse "$merge^1")"

  local stamp dir branch
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$REPLAYS/$issue-$stamp"; branch="eval/$issue-$stamp"
  local env_args=() arm_json="{}"
  for a in "${arms[@]}"; do
    local exp="${a%%=*}" val="${a#*=}"
    case "$exp" in impl|plan) ;; *) die "--arm takes impl=<arm> or plan=<arm>" ;; esac
    case "$val" in inline|delegate) ;; *) die "an arm is inline or delegate" ;; esac
    env_args+=("EVAL_SHIP_ISSUE_ARM_$(tr '[:lower:]' '[:upper:]' <<<"$exp")=$val")
    arm_json="$(jq -c --arg k "$exp" --arg v "$val" '. + {($k): $v}' <<<"$arm_json")"
  done
  local prompt="Use the ship-issue skill with: eval afk #$issue base=$base. Write the handover to $dir/handover.md as well."
  if [ "$dry" = 1 ]; then
    echo "repo=$slug issue=#$issue pr=#$pr base_ref=$base_ref base=$base"
    echo "worktree=$dir/wt branch=$branch model=$model plugin=$plugin_dir arms=$arm_json"
    echo "prompt: $prompt"
    return 0
  fi

  mkdir -p "$dir"
  git -C "$repo" worktree add -q -b "$branch" "$dir/wt" "$base"
  jq -n --arg repo "$slug" --arg checkout "$repo" --argjson issue "$issue" --argjson pr "$pr" \
    --arg base "$base" --arg merge "$merge" --arg branch "$branch" --arg model "$model" \
    --arg plugin "$plugin_dir" --argjson arms "$arm_json" --arg started "$stamp" \
    '{repo: $repo, checkout: $checkout, issue: $issue, pr: $pr, base: $base, merge: $merge,
      branch: $branch, model: $model, plugin: $plugin, arms: $arms, started: $started}' >"$dir/meta.json"
  git -C "$repo" diff "$base" "$merge" >"$dir/reference.patch"
  if [ -n "$setup" ]; then (cd "$dir/wt" && bash -c "$setup") >"$dir/setup.log" 2>&1 || die "setup failed: $dir/setup.log"; fi

  local claude_args=(-p --model "$model" --output-format json --permission-mode bypassPermissions
    --plugin-dir "$plugin_dir" --settings '{"enabledPlugins":{"ship-issue@subhan-skills":false}}')
  [ -z "$budget" ] || claude_args+=(--max-budget-usd "$budget")
  echo "replaying #$issue (PR #$pr) in $dir/wt on $model, arms $arm_json" >&2
  set +e
  (cd "$dir/wt" && env "${env_args[@]}" claude "${claude_args[@]}" "$prompt") >"$dir/result.json" 2>"$dir/claude.log"
  local status=$?
  set -e
  git -C "$dir/wt" diff "$base" HEAD >"$dir/run.patch" || true
  jq --argjson s "$status" '. + {exitCode: $s, finished: (now | todate)}' "$dir/meta.json" >"$dir/meta.tmp" && mv "$dir/meta.tmp" "$dir/meta.json"
  echo "$dir"
}

cmd_grade() {
  local dir="${1:-}"; shift || true
  local judge="opus"
  while [ $# -gt 0 ]; do
    case "$1" in --judge-model) judge="$2"; shift 2 ;; *) die "unknown argument $1" ;; esac
  done
  [ -f "$dir/meta.json" ] || die "no replay at $dir"
  local slug issue body
  slug="$(jq -r .repo "$dir/meta.json")"; issue="$(jq -r .issue "$dir/meta.json")"
  body="$(gh issue view "$issue" -R "$slug" --json title,body -q '"# " + .title + "\n\n" + .body')"
  local schema='{"type":"object","additionalProperties":false,
    "required":["criteria","criteriaMet","criteriaTotal","regressions","verdict","notes"],
    "properties":{
      "criteria":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["criterion","met","evidence"],
        "properties":{"criterion":{"type":"string"},"met":{"type":"boolean"},"evidence":{"type":"string"}}}},
      "criteriaMet":{"type":"integer"},"criteriaTotal":{"type":"integer"},
      "regressions":{"type":"array","items":{"type":"string"}},
      "verdict":{"type":"string","enum":["better","same","worse"]},
      "notes":{"type":"string"}}}'
  {
    echo "You grade a replay of a GitHub issue. The REFERENCE patch is the PR that shipped it;"
    echo "the RUN patch is a new attempt. Derive the acceptance criteria from the issue, decide for"
    echo "each whether the RUN patch meets it (cite the code), list behaviour the RUN patch breaks"
    echo "that the reference keeps, and give a verdict on the RUN against the REFERENCE: better,"
    echo "same, or worse. Judge correctness and completeness, not style or size."
    echo; echo "=== ISSUE"; echo "$body"
    echo; echo "=== HANDOVER (the run's own report)"; cat "$dir/handover.md" 2>/dev/null || echo "(none)"
    echo; echo "=== REFERENCE patch"; head -c 150000 "$dir/reference.patch"
    echo; echo "=== RUN patch"; head -c 150000 "$dir/run.patch"
  } >"$dir/grade-prompt.md"
  claude -p --model "$judge" --output-format json --json-schema "$schema" \
    --settings '{"enabledPlugins":{"ship-issue@subhan-skills":false}}' <"$dir/grade-prompt.md" >"$dir/grade-raw.json"
  jq '.structured_output // (.result | fromjson)' "$dir/grade-raw.json" >"$dir/grade.json"
  jq -r '"\(.criteriaMet)/\(.criteriaTotal) criteria met, verdict \(.verdict), \(.regressions | length) regression(s)"' "$dir/grade.json"
}

cmd_report() {
  local since="1970-01-01"
  while [ $# -gt 0 ]; do
    case "$1" in --since) since="$2"; shift 2 ;; *) die "unknown argument $1" ;; esac
  done
  local runs; runs="$("$scripts/usage-report.sh" --since "$since" --json 2>/dev/null || echo '[]')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' replay issue arms model cost-usd cache-read review-rounds criteria verdict
  for meta in "$REPLAYS"/*/meta.json; do
    [ -f "$meta" ] || continue
    local dir; dir="$(dirname "$meta")"
    jq -r --slurpfile result <(cat "$dir/result.json" 2>/dev/null || echo '{}') \
          --slurpfile grade <(cat "$dir/grade.json" 2>/dev/null || echo '{}') \
          --argjson runs "$runs" --arg wt "$dir/wt" --arg name "$(basename "$dir")" '
      ($runs | map(select(.cwd == $wt)) | last) as $r
      | [$name, .issue,
         (.arms | to_entries | map(.key + ":" + .value) | join(",") | if . == "" then "-" else . end),
         .model, ($result[0].total_cost_usd // "-"),
         ($r.claude.cache_read // "-"), ($r.reviewRounds // "-"),
         (if $grade[0].criteriaTotal then "\($grade[0].criteriaMet)/\($grade[0].criteriaTotal)" else "-" end),
         ($grade[0].verdict // "-")] | @tsv' "$meta"
  done
}

sub="${1:-}"; shift || true
case "$sub" in
  run) cmd_run "$@" ;;
  grade) cmd_grade "$@" ;;
  report) cmd_report "$@" ;;
  *) die "usage: replay.sh run|grade|report ..." ;;
esac
