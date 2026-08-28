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

With `afk` in the invocation, each pick instead runs as its own dispatched t3
thread in `ship-issue` AFK mode — self-contained, self-merging, a sidebar
thread with a live transcript — and the tick drains every eligible sub-issue
before stopping.

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

Attended (default): run the `ship-issue` skill on the picked sub-issue, end to
end, in this session. Its criteria gate stays live — the epic body's decisions
are context for the criteria draft, not a substitute for the human's
confirmation.

AFK (the invocation says `afk`): dispatch the pick as its own **t3 thread** via
`scripts/t3-dispatch.sh` — a real sidebar thread with a full live transcript,
where an Agent-tool subagent shows only title and token count:

- Make a fresh worktree of `<repo>` on a new branch, write the run's prompt to
  a file — "Invoke the ship-issue skill with: afk #<n>. When it finishes, post
  the handover report as a comment on issue #<n>." — then:

  ```bash
  scripts/t3-dispatch.sh --project-root <repo> --title "ship-issue #<n>" \
    --prompt-file <f> --worktree <worktree> --branch <branch>
  ```

  It prints the created threadId. First use pairs with the local t3 server and
  caches a bearer under `~/.local/state/ship-issue/`.
- The issue comment is the completion signal and the report channel: poll it
  (and the ledger's `run-end`) at a few-minute interval for the outcome.
- Independent picks may run concurrently; a pick whose blocker is in flight
  waits for that blocker's merge.
- A run that reports not-AFK-eligible (deep tier, unanswerable question) parks
  its sub-issue for an attended tick — never retry it AFK.

## 4. Continue or report

Attended: after handover, loop to step 2 only when the next pick is independent
of every PR this tick opened, and at most two sub-issues have shipped this
session — past that, context outgrows the tick.

AFK: runs self-merge, so keep draining — after each run's report, refresh the
survey and dispatch the next unblocked pick, until the epic has no eligible open
sub-issue left.

End every tick with the status table from step 1, refreshed: what shipped or
merged, what is parked for an attended tick, what waits on the human, and what
the next tick will pick up.
