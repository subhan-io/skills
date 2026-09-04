---
name: ship-epic
description: Work an epic's sub-issues through the ship-issue skill, one tick at a time.
disable-model-invocation: true
---

# Ship an epic

A thin wrapper around the `ship-issue` skill. One invocation is one **tick**:
survey the epic, ship the next sub-issue(s), report, stop. The human merges PRs
between ticks; re-invoke to continue. All of `ship-issue`'s gates, ledger
writes, and cost rules apply unchanged inside each run.

Two things belong to the epic rather than to any one sub-issue:

- **A stack.** A sub-issue whose blocker is still open branches off that
  blocker and opens its PR against it, so the work starts before the merge and
  each PR still shows only its own diff. Merges are squashes, so every merge
  costs a restack (step 4) — which is why only real dependents stack.
- **A database.** One database per (app, epic), shared by every sub-issue, so
  migrations compose and are proven in order without touching the dev database.

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

The next sub-issue is the first in build order that is open and has no PR. A
blocker that is unmerged no longer disqualifies it — the pick stacks on that
blocker instead (step 3). If none qualifies, report what each remaining
sub-issue waits on (a review, a human answer) and stop the tick.

**Stack only real dependents.** A pick whose blocker is still open branches from
that blocker's head and opens its PR with `--base <blocker-branch>`. A pick with
no open blocker branches from the base branch, as before, and keeps its PR on
the base. Independent picks must stay independent — do not chain them for
tidiness, because every link costs a rebase later.

Stack no deeper than three. Past that, one merge rebases too much and every
review above it goes stale. When the next pick would be a fourth, stop the tick
and say the stack is full.

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
  (and the ledger's `run-end`) at a few-minute interval for the outcome. When a
  run's outcome is `merged`, settle its thread —
  `scripts/t3-dispatch.sh settle <threadId>` — so the sidebar shows only runs
  that still need the human. Any other outcome leaves the thread unsettled.
- Independent picks may run concurrently. A pick that stacks on an in-flight
  blocker may also start, but it must not merge before its blocker: an AFK run
  merges its own PR, and merging a stacked PR into its blocker's branch buries
  the work instead of shipping it. Tell such a run to hand over unmerged, and
  merge it yourself in a later tick once the restack has retargeted it onto the
  base branch.
- A run that reports not-AFK-eligible (deep tier, unanswerable question) parks
  its sub-issue for an attended tick — never retry it AFK.

## 4. Restack after every merge

The base repository squash-merges, so a merge rewrites the merged branch's
commits. Every branch stacked above it is now on a stale base and its diff would
re-show the merged work. Repair the whole stack in one command:

```bash
scripts/stack.sh restack --repo <repo> --base <base-branch>
```

It rebases each tracked branch onto its new parent bottom-up, force-pushes with
a lease, and retargets each PR — a branch whose parent has merged gets reparented
onto the base branch, whether or not the merge deleted it. Run it immediately
after any merge lands, attended or AFK, before picking again.

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

When the rebase conflicts, the script stops and leaves the branch untouched.
Resolve it by hand, then re-run — never let the epic continue on a half-restacked
stack. A failed push is undone the same way: the branch is rolled back to where
it started, so a re-run redoes the whole step rather than believing work that
never reached the remote.

## 5. Continue or report

Attended: after handover, loop to step 2 while the stack is under three deep and
at most two sub-issues have shipped this session — past that, context outgrows
the tick.

AFK: runs self-merge, so keep draining — after each run's report, restack (step
4), refresh the survey, and dispatch the next pick, until the epic has no
eligible open sub-issue left.

End every tick with the status table from step 1, refreshed: what shipped or
merged, what is parked for an attended tick, what waits on the human, and what
the next tick will pick up. Add the stack as `scripts/stack.sh list` prints it,
so the human can see what a merge will rebase before they merge it, and name the
epic database and whether this tick migrated it.
