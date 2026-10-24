#!/usr/bin/env bash
# usage-report.sh — what each ship-issue run cost, joined from the ledger and the
# session logs both harnesses leave on disk.
#
#   usage-report.sh [--since 2026-08-18] [--run <id>] [--json | --by-arm]
#
# --run narrows the report to one run, ignoring --since: the hand-over step prints
# that run's friction (verify failures, review rounds, findings) beside its cost.
#
# Per run (a run-start event, closed by its run-end):
#   - Events join by the run id stamped at run-start when present; older ledger
#     rows without one fall back to issue + time window.
#   - Codex (runs before implementers moved to Claude subagents, 2026-10):
#     distinct sessions (empty sessionId rows are failures, not sessions);
#     token totals dedupe by sessionId keeping the LAST event per session, because
#     a rollout's total_token_usage is cumulative — summing a chunk event and its
#     resume event would double count.
#   - Claude: assistant-message usage from the exact transcript recorded as
#     claudeSession at run-start, plus that session's Agent-tool subagent
#     transcripts (<session>/subagents/*.jsonl); runs without one fall back to
#     every transcript in the cwd's project dir within the time window
#     (overlapping runs in one worktree double count under this fallback). Raw
#     tokens, split cache-read / cache-write / output — cache reads dominate and
#     are what subscription limits mostly meter. `models` lists every model that
#     answered, with its message count, so a run that landed on Fable shows it.
#     `orch%` is the orchestrator session's share of the cache reads (the rest is
#     its subagents); each orchestrator turn replays its whole context, so a run
#     whose orchestrator does implementer work shows a high share.
#   - Nested runs: a run that starts inside another run's window in the same
#     claudeSession (a ship-epic tick and the attended sub-issue it ships) is
#     subtracted from the outer run, so the tick row shows only the tick's own
#     turns.
#   - Phase events (event=phase) are listed per run in --json output.
#   - Experiments: `arms` holds each arm.sh assignment as experiment:arm (a
#     trailing `!` marks an arm the human or an eval case forced). --by-arm
#     prints one row per mode (prod or eval), experiment and arm instead of one
#     row per run, over finished runs whose arm was not forced: runs, merged,
#     medians of cache reads, orch% and minutes, review rounds, valid findings
#     and verify failures. Compare arms on this table, never on one run.
#   - Review rounds: `reviewers` lists who settled each round (codex, or claude
#     when review.sh fell back on a spent Codex quota). Codex reviews run
#     ephemeral and leave no session log, so their cost is not on disk; a Claude
#     fallback review logs its token usage on the event, added to the cl-* totals.
#   - A run resumed after a stop keeps its run id and logs a second run-end; the
#     last one is the run's outcome.
# A run with no run-end is reported as open, window capped at now. Once it is a
# day old it is reported as abandoned instead, its window ending at its last
# event, so a dead run neither reads as live nor absorbs later sessions.
set -euo pipefail

LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"

# Same walk-up as ledger.sh: the transcript dir is keyed by the session's starting
# directory, which may be any ancestor of the run's cwd. Prints every ancestor's
# transcript dir that exists, nearest first. The recorded claudeSession is looked
# up across all of them; the window fallback uses only the nearest.
claude_project_dirs() {
  local d="$1" p
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    p="$HOME/.claude/projects/$(echo "$d" | sed 's|[/.]|-|g')"
    ls "$p"/*.jsonl >/dev/null 2>&1 && echo "$p"
    d="$(dirname "$d")"
  done
  return 0
}

SINCE="$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
AS_JSON=false
BY_ARM=false
RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) case "$2" in *T*) SINCE="$2" ;; *) SINCE="$2T00:00:00Z" ;; esac; shift 2 ;;
    --run) RUN="$2"; SINCE="1970-01-01T00:00:00Z"; shift 2 ;;
    --json) AS_JSON=true; shift ;;
    --by-arm) BY_ARM=true; shift ;;
    *) echo "usage-report.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -f "$LEDGER" ] || { echo "no ledger at $LEDGER" >&2; exit 1; }
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

runs="$(jq -s --arg since "$SINCE" --arg now "$NOW" '
  map(select(.ts >= $since)) as $ev
  | def toks: (.tokens | if type == "string" then (try fromjson catch null) else . end);
  def belongs($s; $e):                       # does event `.` belong to run $s?
      if ($s.run // "") != "" and (.run // "") != "" then .run == $s.run
      else (.issue|tostring) == ($s.issue|tostring)
           and .ts >= $s.ts and .ts <= ($e.ts // $now)
      end;
  [$ev[] | select(.event == "run-start")]
  | map(. as $s
      | ([$ev[] | select(.event == "run-end")
                | select(if ($s.run // "") != "" and (.run // "") != ""
                         then .run == $s.run
                         else (.issue|tostring) == ($s.issue|tostring) and .ts >= $s.ts end)]
         | if ($s.run // "") != "" then last else first end) as $e0
      | (($now | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
         - ($s.ts | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) > 86400) as $stale
      | (if $e0 == null and $stale and ($s.run // "") != ""
         then {ts: ([$ev[] | select(.run == $s.run) | .ts] | max), outcome: "abandoned"}
         else $e0 end) as $e
      | ([$ev[] | select(.event == "codex") | select(belongs($s; $e))]) as $cx
      | ($cx | map(select((.sessionId // "") != ""))
             | group_by(.sessionId)
             | map(max_by((toks // {} | .total_tokens) // -1))) as $sess   # per session: cumulative totals, skip null rows
      | {run: ($s.run // null), issue: ($s.issue|tostring), tier: ($s.tier // "?"),
         cwd: ($s.cwd // ""), claudeSession: ($s.claudeSession // null), model: ($s.model // null),
         mode: ($s.mode // "prod"),
         start: $s.ts, end: ($e.ts // $now), open: ($e == null),
         durationMin: ((((($e.ts // $now) | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
                        - ($s.ts | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime)) / 60) | round),
         outcome: ($e.outcome // "open"), pr: ($e.pr // null),
         chunks: ($e.chunks // null), reviewRounds: ($e.reviewRounds // null),
         findingsValid: ($e.findingsValid // null), findingsInvalid: ($e.findingsInvalid // null),
         verifyRetries: ($e.verifyRetries // null),
         phases: ([$ev[] | select(.event == "phase") | select(belongs($s; $e))
                         | {phase, ts, round: (.round // null), chunk: (.chunk // null),
                            reviewer: (.reviewer // null), reviewUsage: (.reviewUsage // null),
                            experiment: (.experiment // null), arm: (.arm // null),
                            forced: (.forced // null)}]),
         arms: ([$ev[] | select(.event == "phase" and .phase == "arm") | select(belongs($s; $e))
                 | {key: .experiment, value: {arm, forced: (.forced == true)}}]
                | unique_by(.key) | from_entries),
         errors: ([$cx[] | select(.exitCode != 0) | {role, ts, exitCode, error: (.error // "")}]),
         codexFailures: ([$cx[] | select(.exitCode != 0)] | length),
         verifyFailed: ([$ev[] | select(.event == "phase" and .phase == "verify-failed") | select(belongs($s; $e))] | length),
         codex: ($sess
                 | {sessions: length,
                    roles: (map(.role) | group_by(.) | map({(.[0]): length}) | add // {}),
                    total: (map(toks | .total_tokens // 0) | add // 0),
                    uncached: (map(toks
                                   | if . == null then 0
                                     else ((.input_tokens // 0) - (.cached_input_tokens // 0) + (.output_tokens // 0)) end)
                               | add // 0)})})
' "$LEDGER")"
if [ -n "$RUN" ]; then
  runs="$(jq --arg r "$RUN" 'map(select(.run == $r))' <<<"$runs")"
  [ "$(jq 'length' <<<"$runs")" -gt 0 ] || { echo "no run $RUN in $LEDGER" >&2; exit 1; }
fi

report="[]"
n="$(jq 'length' <<<"$runs")"
for i in $(seq 0 $((n - 1))); do
  run="$(jq -c ".[$i]" <<<"$runs")"
  cwd="$(jq -r '.cwd' <<<"$run")"
  start="$(jq -r '.start' <<<"$run")"
  end="$(jq -r '.end' <<<"$run")"
  claude_session="$(jq -r '.claudeSession // ""' <<<"$run")"
  claude='{"msgs":0,"cache_read":0,"orch_cache_read":0,"cache_write":0,"out":0,"models":{},"join":"none"}'
  # Windows of runs nested inside this one in the same session: excluded below.
  nested="$(jq -c --argjson r "$run" '[.[] | select(.run != $r.run and .claudeSession != null
              and .claudeSession == $r.claudeSession and .start >= $r.start and .start <= $r.end)
              | {s: .start, e: .end}]' <<<"$runs")"
  if [ -n "$cwd" ]; then
    proj_dirs="$(claude_project_dirs "$cwd")"
    proj_dir=""
    [ -n "$claude_session" ] && proj_dir="$(for d in $proj_dirs; do [ -f "$d/$claude_session" ] && echo "$d" && break; done || true)"
    files="" join="none"
    if [ -n "$proj_dir" ]; then
      files="$proj_dir/$claude_session"; join="session"
      sub_dir="$proj_dir/${claude_session%.jsonl}/subagents"
      [ -d "$sub_dir" ] && files="$files"$'\n'"$(find "$sub_dir" -name '*.jsonl' 2>/dev/null)"
    elif [ -n "$proj_dirs" ]; then
      # No exact session on record: the nearest dir alone, so a far ancestor's
      # unrelated sessions (a session started in $HOME) do not count here.
      nearest="$(echo "$proj_dirs" | head -1)"
      files="$(find "$nearest" -name '*.jsonl' -newermt "${start%Z}" 2>/dev/null)"; join="window"
    fi
    if [ -n "$files" ]; then
      claude="$(echo "$files" \
        | tr '\n' '\0' | xargs -0 jq -c --arg s "$start" --arg e "$end" --argjson nested "$nested" \
            'select(.type == "assistant" and .message.usage and .timestamp >= $s and .timestamp <= $e)
             | select(.timestamp as $t | any($nested[]; $t >= .s and $t <= .e) | not)
             | {id: (.message.id // "x"), u: .message.usage, model: (.message.model // "?"),
                sub: (input_filename | test("/subagents/"))}' 2>/dev/null \
        | jq -s --arg join "$join" '(group_by(.id) | map(.[-1])) as $m
                 | {msgs: ($m|length),
                    cache_read: ($m | map(.u.cache_read_input_tokens // 0) | add // 0),
                    orch_cache_read: ($m | map(select(.sub | not) | .u.cache_read_input_tokens // 0) | add // 0),
                    cache_write: ($m | map(.u.cache_creation_input_tokens // 0) | add // 0),
                    out: ($m | map(.u.output_tokens // 0) | add // 0),
                    models: ($m | group_by(.model) | map({(.[0].model): length}) | add // {}),
                    join: $join}')"
      [ -n "$claude" ] || claude='{"msgs":0,"cache_read":0,"orch_cache_read":0,"cache_write":0,"out":0,"models":{},"join":"none"}'
    fi
  fi
  # Claude fallback reviews ran headless in their own session: add the usage they logged.
  claude="$(jq -c --argjson r "$run" '
    ([$r.phases[] | select(.phase == "review-settled" and .reviewUsage != null) | .reviewUsage | to_entries[]]) as $u
    | .cache_read += ($u | map(.value.cacheRead // 0) | add // 0)
    | .cache_write += ($u | map(.value.cacheWrite // 0) | add // 0)
    | .out += ($u | map(.value.out // 0) | add // 0)
    | .models += ($u | group_by(.key) | map({(.[0].key + "(review)"): length}) | add // {})' <<<"$claude")"
  report="$(jq -c --argjson r "$run" --argjson c "$claude" '. + [$r + {claude: $c}]' <<<"$report")"
done

if $AS_JSON; then
  jq . <<<"$report"
  exit 0
fi

if $BY_ARM; then
  echo "ship-issue experiment arms since $SINCE  (finished runs, forced arms excluded)"
  jq -r '
    def median: sort | if length == 0 then null else .[(length / 2 | floor)] end;
    def m: if . == null then "-" else tostring | if (.|length) > 6 then (.[0:-6] + "." + .[-6:-5] + "M") else . end end;
    (["mode","experiment","arm","runs","merged","med-cread","med-orch%","med-min","rr/run","valid/run","vfail"] | @tsv),
    ([.[] | select(.open | not) | . as $r | .arms | to_entries[]
          | select(.value.forced | not)
          | {mode: $r.mode, exp: .key, arm: .value.arm, r: $r}]
     | group_by([.mode, .exp, .arm])[]
     | (map(.r)) as $rs
     | [.[0].mode, .[0].exp, .[0].arm, ($rs | length),
        ($rs | map(select(.outcome == "merged" or .outcome == "pr-open")) | length),
        ($rs | map(.claude.cache_read) | median | m),
        ($rs | map(select(.claude.cache_read > 0) | (.claude.orch_cache_read * 100 / .claude.cache_read | floor)) | median // "-"),
        ($rs | map(.durationMin) | median // "-"),
        ($rs | map(.reviewRounds // 0) | (add / length * 10 | round / 10)),
        ($rs | map(.findingsValid // 0) | (add / length * 10 | round / 10)),
        ($rs | map(.verifyFailed) | add)] | @tsv)
  ' <<<"$report" | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else awk -F'\t' '{for (i=1;i<=NF;i++) printf "%-12s", $i; print ""}'; fi
  exit 0
fi

echo "ship-issue runs since $SINCE  (cl-join: session = exact transcript, window = cwd+time fallback, may double count overlaps)"
jq -r '
  def m: tostring | if (.|length) > 6 then (.[0:-6] + "." + .[-6:-5] + "M") else . end;
  def models: to_entries | map((.key | sub("^claude-"; "")) + ":" + (.value|tostring)) | join(" ") | if . == "" then "-" else . end;
  def reviewers: [.phases[] | select(.phase == "review-settled") | (.reviewer // "codex")]
                 | join(",") | if . == "" then "-" else . end;
  def arms: (.arms // {}) | to_entries | map(.key + ":" + .value.arm + (if .value.forced then "!" else "" end))
            | join(",") | if . == "" then "-" else . end;
  (["issue","tier","start","min","outcome","chk","rr","reviewers","vfail","find-ok/bad","arms","cl-cread","orch%","cl-cwrite","cl-out","cl-models","cl-join"] | @tsv),
  (.[] | [(if .mode == "eval" then .issue + "(eval)" else .issue end), .tier, (.start[0:16] + " "), .durationMin, .outcome,
          (.chunks // "-"), (.reviewRounds // "-"), reviewers,
          .verifyFailed,
          ((.findingsValid // "-"|tostring) + "/" + (.findingsInvalid // "-"|tostring)),
          arms,
          (.claude.cache_read|m),
          (if .claude.join == "session" and .claude.cache_read > 0
           then ((.claude.orch_cache_read * 100 / .claude.cache_read | floor | tostring) + "%") else "-" end),
          (.claude.cache_write|m), (.claude.out|m), (.claude.models|models), .claude.join] | @tsv)
' <<<"$report" | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else awk -F'\t' '{for (i=1;i<=NF;i++) printf "%-16s", $i; print ""}'; fi
