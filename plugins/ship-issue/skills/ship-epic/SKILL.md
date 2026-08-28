---
name: ship-epic
description: Work an epic's sub-issues through the ship-issue skill, one tick at a time.
disable-model-invocation: true
---

# Ship an epic

A thin wrapper around the `ship-issue` skill. One invocation is one **tick**:
survey the epic, ship the next unblocked sub-issue(s), report, stop. The human
merges PRs between ticks; re-invoke to continue. All of `ship-issue`'s gates,
ledger writes, and cost rules apply unchanged inside each run.

## 1. Survey

Read the epic (`gh issue view <n>`) and its native sub-issues:

```bash
gh api graphql -f query='query{repository(owner:"<o>",name:"<r>"){issue(number:<n>){
  subIssues(first:50){nodes{number title state}}}}}'
```

For each open sub-issue, find any PR that references it (`gh pr list --search
"<number> in:body"`). Build one status table: sub-issue, state, PR state
(none / open / green / merged), and blockers.

Blockers come from the epic body's build order. If the body states no order,
put your proposed order to the human in one AskUserQuestion, then edit it into
the epic body so later ticks read it instead of asking.

## 2. Pick

The next sub-issue is the first in build order that is open, has no PR, and has
no blocker that is unmerged. If none qualifies, report what each remaining
sub-issue waits on (a merge, a review, a human answer) and stop the tick.

## 3. Ship

Run the `ship-issue` skill on the picked sub-issue, end to end, in this
session. Its criteria gate stays live — the epic body's decisions are context
for the criteria draft, not a substitute for the human's confirmation.

## 4. Continue or report

After handover, loop to step 2 only when the next pick is independent of every
PR this tick opened, and at most two sub-issues have shipped this session —
past that, context outgrows the tick.

End every tick with the status table from step 1, refreshed: what shipped,
what waits on the human, and what the next tick will pick up.
