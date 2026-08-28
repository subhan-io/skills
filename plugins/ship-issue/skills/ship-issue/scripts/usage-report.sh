#!/usr/bin/env bash
# usage-report.sh — what each ship-issue run cost, joined from the ledger and the
# session logs both harnesses leave on disk.
#
#   usage-report.sh [--since 2026-08-18] [--json]
#
# Per run (a run-start event, closed by its run-end):
#   - Events join by the run id stamped at run-start when present; older ledger
#     rows without one fall back to issue + time window.
#   - Codex: distinct sessions (empty sessionId rows are failures, not sessions);
#     token totals dedupe by sessionId keeping the LAST event per session, because
#     a rollout's total_token_usage is cumulative — summing a chunk event and its
#     resume event would double count.
#   - Claude: assistant-message usage from the exact transcript recorded as
#     claudeSession at run-start; runs without one fall back to every transcript
#     in the cwd's project dir within the time window (overlapping runs in one
#     worktree double count under this fallback). Raw tokens, split cache-read /
#     cache-write / output — cache reads dominate and are what subscription
#     limits mostly meter.
#   - Phase events (event=phase) are listed per run in --json output.
# A run with no run-end is reported as open, window capped at now.
set -euo pipefail

LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
SINCE="$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
AS_JSON=false
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="$2T00:00:00Z"; shift 2 ;;
    --json) AS_JSON=true; shift ;;
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
         | first) as $e
      | ([$ev[] | select(.event == "codex") | select(belongs($s; $e))]) as $cx
      | ($cx | map(select((.sessionId // "") != ""))
             | group_by(.sessionId)
             | map(max_by((toks // {} | .total_tokens) // -1))) as $sess   # per session: cumulative totals, skip null rows
      | {run: ($s.run // null), issue: ($s.issue|tostring), tier: ($s.tier // "?"),
         cwd: ($s.cwd // ""), claudeSession: ($s.claudeSession // null),
         start: $s.ts, end: ($e.ts // $now), open: ($e == null),
         durationMin: ((((($e.ts // $now) | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
                        - ($s.ts | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime)) / 60) | round),
         outcome: ($e.outcome // "open"), pr: ($e.pr // null),
         chunks: ($e.chunks // null), reviewRounds: ($e.reviewRounds // null),
         findingsValid: ($e.findingsValid // null), findingsInvalid: ($e.findingsInvalid // null),
         verifyRetries: ($e.verifyRetries // null),
         phases: ([$ev[] | select(.event == "phase") | select(belongs($s; $e))
                         | {phase, ts, round: (.round // null), chunk: (.chunk // null)}]),
         errors: ([$cx[] | select(.exitCode != 0) | {role, ts, exitCode, error: (.error // "")}]),
         codex: ($sess
                 | {sessions: length,
                    roles: (map(.role) | group_by(.) | map({(.[0]): length}) | add // {}),
                    total: (map(toks | .total_tokens // 0) | add // 0),
                    uncached: (map(toks
                                   | if . == null then 0
                                     else ((.input_tokens // 0) - (.cached_input_tokens // 0) + (.output_tokens // 0)) end)
                               | add // 0)})})
' "$LEDGER")"

report="[]"
n="$(jq 'length' <<<"$runs")"
for i in $(seq 0 $((n - 1))); do
  run="$(jq -c ".[$i]" <<<"$runs")"
  cwd="$(jq -r '.cwd' <<<"$run")"
  start="$(jq -r '.start' <<<"$run")"
  end="$(jq -r '.end' <<<"$run")"
  claude_session="$(jq -r '.claudeSession // ""' <<<"$run")"
  claude='{"msgs":0,"cache_read":0,"cache_write":0,"out":0,"join":"none"}'
  if [ -n "$cwd" ]; then
    proj_dir="$HOME/.claude/projects/$(echo "$cwd" | sed 's|[/.]|-|g')"
    files="" join="none"
    if [ -n "$claude_session" ] && [ -f "$proj_dir/$claude_session" ]; then
      files="$proj_dir/$claude_session"; join="session"
    elif [ -d "$proj_dir" ]; then
      files="$(find "$proj_dir" -name '*.jsonl' -newermt "${start%Z}" 2>/dev/null)"; join="window"
    fi
    if [ -n "$files" ]; then
      claude="$(echo "$files" \
        | xargs -r cat 2>/dev/null \
        | jq -c --arg s "$start" --arg e "$end" \
            'select(.type == "assistant" and .message.usage and .timestamp >= $s and .timestamp <= $e)
             | {id: (.message.id // "x"), u: .message.usage}' 2>/dev/null \
        | jq -s --arg join "$join" '(group_by(.id) | map(.[-1])) as $m
                 | {msgs: ($m|length),
                    cache_read: ($m | map(.u.cache_read_input_tokens // 0) | add // 0),
                    cache_write: ($m | map(.u.cache_creation_input_tokens // 0) | add // 0),
                    out: ($m | map(.u.output_tokens // 0) | add // 0),
                    join: $join}')"
      [ -n "$claude" ] || claude='{"msgs":0,"cache_read":0,"cache_write":0,"out":0,"join":"none"}'
    fi
  fi
  report="$(jq -c --argjson r "$run" --argjson c "$claude" '. + [$r + {claude: $c}]' <<<"$report")"
done

if $AS_JSON; then
  jq . <<<"$report"
  exit 0
fi

echo "ship-issue runs since $SINCE  (cl-join: session = exact transcript, window = cwd+time fallback, may double count overlaps)"
jq -r '
  def m: tostring | if (.|length) > 6 then (.[0:-6] + "." + .[-6:-5] + "M") else . end;
  (["issue","tier","start","min","outcome","chk","rr","cdx-sess","cdx-total","cdx-uncached","cl-cread","cl-cwrite","cl-out","cl-join"] | @tsv),
  (.[] | [.issue, .tier, (.start[0:16] + " "), .durationMin, .outcome,
          (.chunks // "-"), (.reviewRounds // "-"),
          .codex.sessions, (.codex.total|m), (.codex.uncached|m),
          (.claude.cache_read|m), (.claude.cache_write|m), (.claude.out|m), .claude.join] | @tsv)
' <<<"$report" | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else awk -F'\t' '{for (i=1;i<=NF;i++) printf "%-16s", $i; print ""}'; fi
