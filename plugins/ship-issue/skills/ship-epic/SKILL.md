---
name: ship-epic
description: Work an epic's sub-issues one tick at a time, or drain it unattended into its integration branch with afk.
disable-model-invocation: true
---

# Ship an epic

A thin wrapper around the `ship-issue` skill. An attended invocation is one
**tick**: survey the epic, ship the next sub-issue(s), report, stop; re-invoke to
continue. All of `ship-issue`'s gates, ledger writes, and cost rules apply
unchanged inside each run.

Two things belong to the epic rather than to any one sub-issue:

- **An integration branch.** `epic/<n>`, forked from the base branch. Every
  sub-issue branches from its tip, opens its PR against it, and merges into it,
  so parallel sub-issues never need a rebase. The human merges `epic/<n>` into
  the base branch once, as the feature's PR.
- **Scratch databases.** One per (app, sub-issue), built from the sub-issue's
  branch, so its migrations run in order on top of everything merged into
  `epic/<n>`, without touching the dev database.

With `afk` in the invocation, each pick instead runs as its own top-level T3
thread in `ship-issue` AFK mode, launched into its own worktree through the
`t3-code` MCP server, with a sidebar entry and live transcript. AFK
means unattended end to end: a launched run merges its own PR into `epic/<n>`
once it is review-ready, and the epic run keeps picking until every sub-issue is
in. An issue carrying the `hitl` label is a barrier: ship and merge that issue
too, then stop without starting any later issue. A later invocation continues
after the human has handled the checkpoint.

## 1. Survey

The epic body is the tick's memory. Its build order lives there, and so does a
status block between `<!-- ship-epic:status -->` markers that step 5 rewrites whole
at the end of every tick. From the block, take the build order and the notes on
what is parked or waits on the human. Its PR and CI states were true when the
last tick wrote them: re-query every one below (a tick once reported a PR green
that had since failed typecheck).

Start the tick's ledger run and keep the id for the run-end in step 5. The
tick's own subagents (step 4) count toward it. `<ship-issue>` below is the sibling
`ship-issue` skill directory, beside this one.

```bash
tick=$(<ship-issue>/scripts/ledger.sh event=run-start issue=epic-<n> tier=epic cwd="$PWD")
```

Pass `cwd` so the tick's own Claude session and model are on record.

Make sure the integration branch exists and carries the base branch's latest:

```bash
scripts/epic-branch.sh ensure --repo <repo> --epic <n> --base <base>
scripts/epic-branch.sh sync   --repo <repo> --epic <n> --base <base>
```

`ensure` creates `epic/<n>` from the base when it is absent. `sync` merges the
base into it and pushes; a conflict goes to step 4 before anything is picked.

Read the epic (`gh issue view <n>`) and its native sub-issues, including labels:

```bash
gh api graphql -f query='query{repository(owner:"<o>",name:"<r>"){issue(number:<n>){
  subIssues(first:50){nodes{number title state labels(first:20){nodes{name}}}}}}'
```

For each open sub-issue, find any PR that references it (`gh pr list --search
"<number> in:body"`). Build one status table: sub-issue, state, PR state
(none / open / green / review-ready / merged into `epic/<n>`), and blockers.
`green` means CI passed; `review-ready` additionally satisfies the completion
test in step 3.

In AFK mode, call `t3_thread_list` with `titleContains: "ship-issue #"` and
`settled: false`. An unsettled thread whose issue has no report yet is a run
already in flight from an earlier invocation: it counts against the concurrency
limit, and its issue gets no second run.

In AFK mode, find the first open issue in build order with a case-insensitive
`hitl` label. That issue is the run's horizon: it remains eligible, while every
issue after it is outside this run. Apply the horizon before launching anything,
including independent work, so concurrency cannot cross the barrier.

Blockers come from the epic body's build order. If the body states no order,
put your proposed order to the human in one AskUserQuestion, then edit it into
the epic body so later ticks read it instead of asking.

## 2. Pick

The next sub-issue is the first in build order that is open, has no PR, and
whose blockers have all merged into `epic/<n>`. A blocker that is open but
unmerged is a wait, not a branch to build on: the pick starts once it lands,
from a tip that holds the blocker's finished work. Independent sub-issues are
eligible together. If none qualifies, report what each remaining sub-issue
waits on (a blocker's merge, a review, a human answer) and stop the attended
tick. In AFK mode, absence of a new pick is not a stopping condition while a
run is in flight: wait for it (step 3).

## 3. Ship

Before the pick's run starts, prepare its branch and its database.

**Branch.** The pick works in a worktree from the tip of `origin/epic/<n>`, on a
new branch. Attended, create it yourself. AFK, the launch creates it (below). The
pick's PR opens with `--base epic/<n>`; name that base to `ship-issue` — in the
invocation for an attended run, in the launch message for an AFK one — and it
passes it to `gh pr create`.

**Database.** Skip this when the sub-issue does not touch the schema or need
real data. Otherwise give it its own database, built from its worktree:

```bash
url_file=$(scripts/epic-db.sh --repo <worktree> --app <app> --epic <n> --issue <sub-issue>)
```

Attended, run it yourself. AFK, the worktree does not exist until T3 prepares
it, so the launch message gives the run this command with `--repo "$PWD"` and the
script's absolute path, and the run executes it. It creates the database if it
is absent, applies the schema, seeds it, and prints the path of a 0600 file
holding the connection string. Pass that path into the run's implementer prompts —
`DATABASE_URL="$(cat <url_file>)"` — and never the URL itself, which would put a password in the transcript and in issue
comments. Re-run the script before each chunk; it picks up the migrations the
chunk added. When the schema fails to apply to an existing database, the script
rebuilds it once by itself, so a failure it reports is a real migration error:
route it to an implementer, and never repair the database by hand.

Concurrent sub-issues must not share a database. Branches with different
migration sets applying to one database left drizzle's journal out of step with
the tables on epic #616, and two runs lost time repairing it by hand.

The database is a pgmanager `scratch` database keyed `epic<n>_<sub-issue>`,
leased for 7 days — so this step needs a repository with an `apps/<app>` layout
and a pgmanager project per app. Extensions come from the app's CI workflow.

Seed data comes from the app's own `db:seed` or `e2e:seed` script, never a dump,
which cannot survive a migration. It must be idempotent, with fixed ids and
emails: it re-runs after every migration, and stable ids keep `ui-evidence`
screenshots comparable across sub-issues. Keep it to one user per auth role and
one row per core entity, with no realistic personal data. When the app has no
seed script, the epic's first sub-issue writes one as a repository asset; rows
the epic needs beyond that baseline go in an overlay later sub-issues extend.

**Epic context.** Every run under this epic gets the same block, built once per
tick and handed to `ship-issue` — in your own context for an attended run, in the
launch message for an AFK one: the epic's goal paragraph, the build order, its
`## Contracts` section, and the refreshed status table. `## Contracts` holds the
decisions sub-issues must agree on: the interfaces they meet at, the dependency
policy (what is written in-repo, which libraries stay out), names that must match
across sub-issues. When the body has none and the epic shares surface across
sub-issues, draft it from the epic and the shipped work and put it to the human
together with the build order, then edit it into the body. A sub-issue's run appends
to it when its plan settles a contract a later sub-issue depends on.

Attended (default): run the `ship-issue` skill on the picked sub-issue, end to
end, in this session. Its criteria gate stays live — the epic body's decisions
are context for the criteria draft, not a substitute for the human's
confirmation. The human merges the sub-issue's PR into `epic/<n>`; the next tick
continues from there.

AFK (the invocation says `afk`): launch the pick as its own top-level **T3
thread** through the `t3-code` MCP server — a sidebar thread with a full live
transcript, bound to its own worktree. The launched run merges its own PR into
`epic/<n>`; the base branch stays the human's. In Claude Code the server's tools
can be deferred: load each `t3-code` tool this step names before its first call.

- **Preflight, once per run.** Call `orchestrator_capabilities`. Its
  `parentThreadId` is this thread's id: every run reports to it. From its
  `providers`, take the Claude provider instance and its Sonnet model id. When
  the tools are absent, stop and report: AFK needs a T3 Code build with the V2
  orchestrator. Launch also requires this thread to run in full-access, default
  mode.
- **Launch.** One `t3_thread_launch` per pick:

  ```json
  {"title": "ship-issue #<n>",
   "modelSelection": {"instanceId": "<claude instance>", "model": "<sonnet id>"},
   "workspaceStrategy": {"type": "worktree", "baseRef": "epic/<epic>",
                         "branch": "<branch>", "startFromOrigin": true},
   "message": "<launch message>"}
  ```

  T3 fetches, creates the worktree from `origin/epic/<epic>`, runs the project's
  setup script, binds the thread to the worktree, and then delivers the message.
  The launch message: "Invoke the ship-issue skill with: afk #<n>. This is a
  ship-epic run for epic #<epic>: open the PR against `epic/<epic>` and, once it
  is review-ready and green, merge it there. When it finishes, post the handover
  report as a comment on issue #<n>, then, as the run's last action, call
  `t3_thread_send` with threadId `<parentThreadId>`, mode `queue`, and message
  `ship-issue #<n> outcome=<run-end outcome> pr=<url> comment=<url>`." Append
  the database command when the pick needs one, then the epic context block.

  The launched thread is the run's orchestrator and runs on Sonnet. **Never pass
  Fable unless the human asked for Fable on that run**; the same holds for every
  Agent-tool subagent either skill spawns. Name the model in chat as you launch,
  and keep the returned threadId beside the issue number for the rest of the
  run. The launch has no retry key: after an error or a lost response, look for
  the thread with `t3_thread_list` before launching again.
- **Wait by ending the turn.** A run's report arrives in this thread as a queued
  message and starts the next turn, so after launching, end the turn. Each report
  turn re-runs the survey and picks again. A pick is review-ready only when its
  full verification and evidence gates passed, its review rounds finished under
  `ship-issue`'s review policy (step 7) with their fixes pushed, and its head
  commit's required checks ran and passed; the run merges on that test and
  nothing weaker.
- **Heartbeat.** A run that crashes, or stops on a question, never reports. With
  the first launch, call `list_scheduled_tasks`; when no heartbeat for this epic
  exists, create one with `schedule_task`: title `ship-epic #<epic> heartbeat`,
  schedule `{"type":"interval","everyMs":3600000}`, bound to this thread, prompt
  "ship-epic heartbeat for epic #<epic>: check every in-flight run." On a
  heartbeat turn, `t3_thread_read` each in-flight thread:
  - `pendingRequestCount > 0`: the run waits on a question that AFK cannot
    answer. Park its sub-issue for an attended tick.
  - status `failed`, `interrupted` or `cancelled`: the run stopped short.
  - idle with no report: read its last messages. A run waiting on background
    work (an implementer, a review) says so; any other idle run stopped short.

  A run that stopped short is a failure (step 5). Interrupt nothing that is
  still working.
- **Settle the thread once its handoff is complete.** When a report says
  `outcome=merged`, call `t3_thread_wait` on its thread (the report was the
  run's last action, so its turn ends within moments), then
  `t3_thread_organize` with `action: "settle"`. When the wait returns
  `timedOut: true`, leave the thread unsettled and say so. A run that stopped
  short — `outcome=stopped` or `pr-open`, not-AFK-eligible, a failed gate —
  keeps its thread unsettled: the marker is the sidebar's record that it needs
  a human, and its transcript is where they read why.
- Independent picks may run concurrently, **three in flight by default**
  (`afk 4` in the invocation changes it); a run is in flight from launch until
  its report arrives. A dependent pick waits until its blocker has merged
  into `epic/<n>` before branching. Never launch past the AFK run's `hitl` horizon.
- A run that reports not-AFK-eligible (criteria unclear from the issue, an
  unanswerable question) parks its sub-issue for an attended tick — never retry
  it AFK.

## 4. Keep the integration branch current

`epic/<n>` drifts from the base branch while the feature builds. Step 1 syncs
it at the start of every tick, and step 5 syncs it again before the epic PR is
opened or refreshed, so the feature's PR always shows the feature's own diff.

```bash
scripts/epic-branch.sh sync --repo <repo> --epic <n> --base <base>
```

It merges the base into `epic/<n>` in a worktree of its own and pushes; when the
branch is current or the merge is clean it prints nothing. On a conflict it
aborts the merge, leaves the worktree clean at `origin/epic/<n>`, and prints one
line on stdout:

```text
conflict branch=epic/<n> base=<base> worktree=<dir>
```

Route it to a sync implementer; a human resolving merge hunks is the tick
stalling. Write a prompt file from those values: in `<worktree>`, run
`git merge origin/<base>`, resolve each hunk preserving the intent of both sides
(the epic's `## Contracts` says what the epic side meant), run the app's verify
command, then `git push origin HEAD:refs/heads/epic/<n>`. Append `anti-slop.md`
and `handoff.md` from the `ship-issue` skill directory with `cat >>`, then
dispatch it with the Agent tool as `ship-issue` step 5 does (`model: sonnet`,
`description: "sync epic/<n>"`), pointing it at the prompt file.

Read the handoff. A pushed, verified merge is followed by `sync` again, which
now prints nothing. A handoff that reports both sides changed one contract
incompatibly is an escalation: leave the branch where the script left it and
take it to the human. Only a pushed merge counts: the next `sync` resets the
worktree to what origin holds.

A conflict in a sub-issue PR opened before a sync belongs to that sub-issue's
run, in a fresh fix implementer before its merge, not to the tick.

## 5. Continue or report

Attended: after handover, loop to step 2 while the session's context stays light;
end the tick when it grows heavy, since every later turn pays for it. Each
sub-issue's PR waits
for the human's merge into `epic/<n>`; the next tick continues from what has
landed.

AFK: keep picking and merging. Refresh the survey after each report and launch
the next pick until either:

- every sub-issue in the epic has merged into `epic/<n>`, making the complete
  feature ready for the human's review; or
- the `hitl` horizon and every issue before it in build order have merged,
  making that checkpoint ready for the human.

Failures and AFK-ineligible issues still stop the run for human attention;
never step around one to continue the feature. A stop launches nothing new; runs
already in flight finish and report. When no run is in flight, delete this
epic's heartbeat with `delete_scheduled_task`, so it does not wake a finished run.

**The epic PR.** The feature reaches the base branch as one PR, `epic/<n>` into
`<base>`. Sync first (step 4), then open it as a draft when the first sub-issue
merges into the branch, and mark it ready only when every sub-issue has merged:

```bash
gh pr create --base <base> --head epic/<n> --draft --title "<epic title> (#<n>)" --body-file <f>
gh pr ready <pr>
```

Link it to this thread with `link_pull_request`, so the sidebar shows its state.
Its body holds the epic link and the list of sub-issue PRs merged into the
branch, each linked; refresh that list every tick. The human merges it — the
skill never does. A `hitl` checkpoint leaves it a draft: the human reads the
draft's diff so far, the merged sub-issue PRs, and the status block, then
re-invokes the run; a partial feature never becomes a ready PR.

End every tick by rewriting the epic's status block: the table from step 1,
refreshed — what merged into `epic/<n>`, what is parked for an attended tick,
what waits on the human, what the next tick will pick up — then the branch as
`scripts/epic-branch.sh status` prints it (drift from the base, PRs merged and
open against it, the epic PR). Write it to a file and replace the block in the
body:

```bash
scripts/epic-status.sh --repo <repo> --epic <n> --file <status.md>
```

It replaces everything between the markers and appends the block on first use, so
the body always holds one current table and never a trail of them. Print the same
table in chat, then close the tick's ledger run:

```bash
<ship-issue>/scripts/ledger.sh event=run-end run="$tick" issue=epic-<n> outcome=tick
```
