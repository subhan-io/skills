#!/usr/bin/env bash
# fable-guard.sh — PreToolUse hook: deny a subagent, delegated task or T3 thread
# that would run on Fable.
#
# ship-issue and ship-epic run implementers and launched threads on Sonnet and
# the deep planner on Opus. A Fable loop costs several times an Opus one, so it
# runs only when the human asked for it. The hook reads the tool input on stdin
# and denies the call when any `model` field in it names Fable. When the human
# has asked for Fable, they allow it by creating ~/.config/ship-issue/allow-fable,
# and delete the file when that work is done.
set -euo pipefail

input="$(cat)"
[ -f "$HOME/.config/ship-issue/allow-fable" ] && exit 0
if jq -e '[.tool_input // {} | .. | objects | to_entries[]
           | select(.key == "model" and (.value | type) == "string") | .value]
          | any(test("fable"; "i"))' >/dev/null 2>&1 <<<"$input"; then
  jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
    permissionDecisionReason: "Fable runs only on the human'"'"'s explicit request: pick sonnet for implementers and launched threads, opus for a planner. If the human asked for Fable on this work, ask them to run `touch ~/.config/ship-issue/allow-fable` (and delete the file afterwards)."}}'
fi
exit 0
