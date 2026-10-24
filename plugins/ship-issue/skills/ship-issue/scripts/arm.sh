#!/usr/bin/env bash
# arm.sh — put this run in one arm of a ship-issue experiment, and log it.
#
#   arm.sh --run <id> --issue <n> --experiment <impl|plan> [--arm <inline|delegate>]
#
# Prints `inline` or `delegate`. The arm is a hash of the run id and the
# experiment, so about half the runs land in each arm, and a resumed run, which
# keeps its run id, gets the arm it had. A second call for the same run and
# experiment prints the logged arm and logs nothing.
#
# Experiments:
#   impl  the approved plan is one chunk: the orchestrator implements it itself
#         (inline), or one fresh Sonnet implementer does (delegate).
#   plan  deep tier: the orchestrator writes the plan itself (inline), or the
#         Opus Plan agent does (delegate).
#
# --arm forces an arm, for when the human chose one. EVAL_SHIP_ISSUE_ARM_IMPL and
# EVAL_SHIP_ISSUE_ARM_PLAN force it too, so a `claude plugin eval` case can pin
# its arm. A forced arm is logged with forced=true, and `usage-report.sh
# --by-arm` leaves forced runs out of the comparison.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
run="" issue="" exp="" arm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --experiment) exp="$2"; shift 2 ;;
    --arm) arm="$2"; shift 2 ;;
    *) echo "arm.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$run" ] && [ -n "$issue" ] || { echo "arm.sh: --run and --issue are required" >&2; exit 2; }
case "$exp" in impl|plan) ;; *) echo "arm.sh: --experiment must be impl or plan" >&2; exit 2 ;; esac

if [ -f "$LEDGER" ]; then
  logged="$(jq -r --arg r "$run" --arg x "$exp" \
    'select(.run == $r and .phase == "arm" and .experiment == $x) | .arm' "$LEDGER" 2>/dev/null | head -1)"
  if [ -n "$logged" ]; then echo "$logged"; exit 0; fi
fi

forced=false
env_var="EVAL_SHIP_ISSUE_ARM_$(tr '[:lower:]' '[:upper:]' <<<"$exp")"
[ -n "$arm" ] || arm="${!env_var:-}"
if [ -n "$arm" ]; then
  forced=true
else
  sum="$(printf '%s:%s' "$run" "$exp" | cksum | cut -d' ' -f1)"
  if [ $((sum % 2)) -eq 0 ]; then arm=inline; else arm=delegate; fi
fi
case "$arm" in inline|delegate) ;; *) echo "arm.sh: arm must be inline or delegate, got '$arm'" >&2; exit 2 ;; esac

"$here/ledger.sh" event=phase phase=arm run="$run" issue="$issue" experiment="$exp" arm="$arm" forced="$forced"
echo "$arm"
