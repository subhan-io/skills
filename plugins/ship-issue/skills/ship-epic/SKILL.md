---
name: ship-epic
description: Work an epic's sub-issues one tick at a time, or build a review-ready stack unattended with afk.
disable-model-invocation: true
---

# Ship an epic

A thin wrapper around the `ship-issue` skill. An attended invocation is one
**tick**: survey the epic, ship the next sub-issue(s), report, stop; re-invoke to
continue building the same unmerged stack. The stack is the feature boundary:
no sub-issue PR merges until every issue in the feature is review-ready. All of
`ship-issue`'s gates, ledger writes, and cost rules apply unchanged inside each
run.

Two things belong to the epic rather than to any one sub-issue:

- **A stack.** A sub-issue whose blocker is still open branches off that
  blocker and opens its PR against it, so the work starts before the merge and
  each PR still shows only its own diff. Merges are squashes, so every merge
  costs a restack (step 4) — which is why only real dependents stack.
- **A database.** One database per (app, epic), shared by every sub-issue, so
  migrations compose and are proven in order without touching the dev database.

With `afk` in the invocation, each pick instead runs as its own dispatched t3
thread in `ship-issue` AFK mode, with a sidebar thread and live transcript. The
epic run keeps the resulting PRs unmerged and continues until the current stack
contains every issue in the feature and is review-ready. An issue carrying the
`hitl` label is a barrier: ship that issue too, then stop without starting any
later issue. A later invocation continues the same stack after the human has
handled the checkpoint.

## 1. Survey

The epic body is the tick's memory. Its build order lives there, and so does a
status block between `<!-- ship-epic:status -->` markers that step 5 rewrites whole
at the end of every tick. Read the block first: it is the last tick's table, and
the survey below refreshes it rather than rebuilding it.

Start the tick's ledger run and keep the id: it stamps the tick's own Codex
sessions (step 4) and the run-end in step 5. `<ship-issue>` below is the sibling
`ship-issue` skill directory, beside this one.

```bash
tick=$(<ship-issue>/scripts/ledger.sh event=run-start issue=epic-<n> tier=epic cwd="$PWD")
```

Pass `cwd` so the tick's own Claude session and model are on record.
`usage-report.sh` subtracts any sub-issue run that starts inside the tick in the
same session, so an attended tick does not count its sub-issue's cost twice.

Read the epic (`gh issue view <n>`) and its native sub-issues, including labels:

```bash
gh api graphql -f query='query{repository(owner:"<o>",name:"<r>"){issue(number:<n>){
  subIssues(first:50){nodes{number title state labels(first:20){nodes{name}}}}}}'
```

For each open sub-issue, find any PR that references it (`gh pr list --search
"<number> in:body"`). Build one status table: sub-issue, state, PR state
(none / open / green / review-ready / merged), and blockers. `green` means CI
passed; `review-ready` additionally satisfies the AFK completion test in step 3.

In AFK mode, find the first open issue in build order with a case-insensitive
`hitl` label. That issue is the run's horizon: it remains eligible, while every
issue after it is outside this run. Apply the horizon before dispatching anything,
including independent work, so concurrency cannot cross the barrier.

Blockers come from the epic body's build order. If the body states no order,
put your proposed order to the human in one AskUserQuestion, then edit it into
the epic body so later ticks read it instead of asking.

## 2. Pick

The next sub-issue is the first in build order that is open and has no PR. A
blocker that is unmerged no longer disqualifies it — the pick stacks on that
blocker instead (step 3). If none qualifies, report what each remaining
sub-issue waits on (a review, a human answer) and stop the attended tick. In AFK
mode, keep polling any target-stack PR that is open but not review-ready; absence
of a new pick is not a successful stopping condition.

**Stack only real dependents.** A pick whose blocker is still open branches from
that blocker's head and opens its PR with `--base <blocker-branch>`. A pick with
no open blocker branches from the base branch, as before, and keeps its PR on
the base. Independent picks must stay independent — do not chain them for
tidiness, because every link costs a rebase later.

The stack spans the whole feature. It has no PR-count or dependency-depth cap;
the build order and real dependencies determine its shape. A long stack may cost
more to restack during the final merge, but that does not justify shipping a
partial feature.

## 3. Ship

Before the pick's run starts, prepare its branch and its database.

**Branch.** Create the worktree from the pick's parent — the blocker's branch
for a stacked pick, the base branch otherwise — then record the link:

```bash
scripts/stack.sh track --repo <repo> --branch <branch> --parent <parent>
```

The record is what makes step 4 able to repair the stack. Skip it and the
branch silently drops out of every later restack.

**Database.** Skip this when no sub-issue of the epic touches the schema or
needs real data. Otherwise every sub-issue of the epic shares one database, so
sub-issue B's migration applies on top of sub-issue A's and an ordering conflict
surfaces while the stack is still open:

```bash
url_file=$(scripts/epic-db.sh --repo <repo> --app <app> --epic <n>)
```

It creates the database if it is absent, applies the schema, seeds it, and
prints the path of a 0600 file holding the connection string. Pass that path
into the run's Codex prompts — `DATABASE_URL="$(cat <url_file>)"` — and never
the URL itself, which would put a password in the transcript and in issue
comments. Re-run the script before each chunk; it is create-if-missing, so the
call is cheap and it picks up the migrations the previous sub-issue added.

The database is a pgmanager `pr`-env database numbered `epic + 9000`, one per
app — so this step needs a repository with an `apps/<app>` layout and a
pgmanager project per app. An epic that touches two apps gets one per app. When a bad migration
poisons it, `--recreate` rebuilds it from migrations and seed in one command —
so nothing in it is ever precious, and nothing needs hand repair.

Seed data is the app's own `db:seed` or `e2e:seed` script, not a fixture this
skill invents and not a database dump — a dump cannot survive a migration. It
must be idempotent and deterministic, with fixed ids and emails, because it
re-runs after every migration and because stable ids keep `ui-evidence`
screenshots comparable across sub-issues. Keep it thin: one user per auth role
and one row per core entity, enough to exercise the foreign keys and the states
the epic touches. No volume data, and no realistic-looking personal data. When
the app has no seed script, the epic's first sub-issue writes one — it is a
repository asset, not scaffolding for this skill. Rows the epic needs beyond
that baseline go in an overlay the first sub-issue adds and later sub-issues
extend; that overlay is what makes a backfill testable.

**Epic context.** Every run under this epic gets the same block, built once per
tick and handed to `ship-issue` — in your own context for an attended run, in the
prompt file for an AFK one: the epic's goal paragraph, the build order, its
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
confirmation.

AFK (the invocation says `afk`): dispatch the pick as its own **t3 thread** via
`scripts/t3-dispatch.sh` — a real sidebar thread with a full live transcript,
where an Agent-tool subagent shows only title and token count. AFK here means
unattended gates, not permission to merge: every dispatched run leaves its PR
open for the human.

- Make a fresh worktree of `<repo>` on a new branch, write the run's prompt to
  a file — "Invoke the ship-issue skill with: afk #<n>. This is a ship-epic
  stack run: leave the PR unmerged even when green and log `outcome=pr-open`.
  When it finishes, post the handover report as a comment on issue #<n>." — then:

  ```bash
  scripts/t3-dispatch.sh --project-root <repo> --title "ship-issue #<n>" \
    --prompt-file <f> --worktree <worktree> --branch <branch> --model claude-sonnet-5
  ```

  The dispatched thread is the run's orchestrator, and it runs on Sonnet.
  **Never dispatch on Fable unless the human asked for Fable on that run**: the
  orchestrator loop is turns × context, and one Fable AFK run cost more than the
  rest of its tick combined. The same rule holds for every Agent-tool subagent
  either skill spawns. Say the model in chat as you dispatch, one line:
  `Dispatching ship-issue #640 as a t3 thread on claude-sonnet-5`. The script
  prints the same line to stderr.

  It prints the created threadId. First use pairs with the local t3 server and
  caches a bearer under `~/.local/state/ship-issue/`.
- The issue comment is the completion signal and the report channel: poll it
  (and the ledger's `run-end`) at a few-minute interval for the outcome. A pick
  is review-ready only when its full verification and evidence gates passed,
  its Codex review settled with no valid finding left unresolved, and required
  PR checks are green. Leave its thread unsettled so the sidebar shows the stack
  waiting for human review.
- Independent picks may run concurrently, **two in flight at most** — a run is in
  flight from dispatch until its issue comment lands. This box also builds and
  serves; a third concurrent run starves all three. A dependent pick waits until
  its blocker is review-ready before branching, so its branch contains the
  blocker's finished work. Never dispatch past the AFK run's `hitl` horizon.
- A run that reports not-AFK-eligible (deep tier, unanswerable question) parks
  its sub-issue for an attended tick — never retry it AFK.

## 4. Restack during the final merge

The base repository squash-merges, so a merge rewrites the merged branch's
commits. Every branch stacked above it is now on a stale base and its diff would
re-show the merged work. Repair the whole stack in one command:

```bash
scripts/stack.sh restack --repo <repo> --base <base-branch>
```

It rebases each tracked branch onto its new parent bottom-up, force-pushes with
a lease, and retargets each PR — a branch whose parent has merged gets reparented
onto the base branch, whether or not the merge deleted it. Building the feature
does not enter this step because its stack stays unmerged. Once the complete
feature is review-ready and merging begins, run it immediately after each merge.

Each rebase runs inside the worktree that holds the branch, since git will not
switch to a branch another worktree has checked out. A dirty worktree therefore
stops the run rather than being rewritten underneath whoever is working in it —
commit or set those changes aside first.

Two consequences to carry into the report:

- A rebase force-push starts a fresh CI run on every branch it moved. Wait for
  those before merging anything else, and never apply a label while one is in
  flight — a cancelled required check blocks the merge permanently.
- A `codex-review` round that ran before a restack is stale. A PR whose content
  the rebase changed needs its round again; a clean replay does not.

When the rebase conflicts, the script stops, leaves the branch untouched, and
prints one line on stdout:

```text
conflict branch=<b> parent=<p> onto=<sha> from=<sha> worktree=<dir>
```

Route it to a Codex restack session; a human resolving merge hunks is the tick
stalling. Write a prompt from those values: in `<worktree>`, run
`git rebase --onto <onto> <from> <b>`, resolve each hunk preserving the intent of
both sides (the merged PR's diff and the epic's `## Contracts` say what the parent
side meant), run the sub-issue's verify command, then
`git push --force-with-lease origin <b>`. Append `anti-slop.md` and `handoff.md`
from the `ship-issue` skill directory, then:

```bash
<ship-issue>/scripts/run-codex.sh --role restack --issue <epic> --run "$tick" \
  --prompt-file <f> --out <f.last.md> --cd <worktree>
```

Read the handoff. A pushed, verified rebase is followed by
`scripts/stack.sh track --repo <repo> --branch <b> --parent <p>`, which re-records
the fork point from the new merge base, and then `restack` again for the rest of
the stack. A handoff that reports both sides changed one contract incompatibly is
an escalation: leave the branch where the script left it and take it to the human.
Never let the epic continue on a half-restacked stack, and never force-push a guess
to make it green. A failed push is undone by the script itself: the branch is
rolled back to where it started, so a re-run redoes the whole step rather than
believing work that never reached the remote.

## 5. Continue or report

Attended: after handover, loop to step 2 until at most two sub-issues have shipped
this session — past that, context outgrows the tick. Leave the stack unmerged;
the next tick continues it.

AFK: keep draining without merging. Refresh the survey after each report and
dispatch the next pick until either:

- every sub-issue in the epic has a review-ready PR, making the complete feature
  ready for human review; or
- the `hitl` horizon's PR and every PR before it in the stack are review-ready,
  making that checkpoint ready for the human.

At a `hitl` horizon, ship the labeled issue and wait for the stack through that
issue to satisfy the review-ready test before stopping. Failures and
AFK-ineligible issues still stop the run for human attention; never step around
one to continue the feature.

End every tick by rewriting the epic's status block: the table from step 1,
refreshed — what shipped or merged, what is parked for an attended tick, what
waits on the human, what the next tick will pick up — then the stack as
`scripts/stack.sh list` prints it, so the human can see what a merge will rebase
before they merge it, and the epic database with whether this tick migrated it.
Write it to a file and replace the block in the body:

```bash
scripts/epic-status.sh --repo <repo> --epic <n> --file <status.md>
```

It replaces everything between the markers and appends the block on first use, so
the body always holds one current table and never a trail of them. Print the same
table in chat, then close the tick's ledger run:

```bash
<ship-issue>/scripts/ledger.sh event=run-end run="$tick" issue=epic-<n> outcome=tick
```
