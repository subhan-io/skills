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
  sub-issue branches from its tip and opens its PR against it, and a finished
  sub-issue merges into it. Parallel sub-issues are then ordinary siblings of one
  branch — nothing to rebase when one of them merges — and a sub-issue that
  depends on two others branches from the tip once both are in. The base branch
  never sees a sub-issue on its own: the human merges `epic/<n>` into it once, as
  the feature's PR.
- **A database.** One database per (app, epic), shared by every sub-issue, so
  migrations compose and are proven in order without touching the dev database.

With `afk` in the invocation, each pick instead runs as its own dispatched t3
thread in `ship-issue` AFK mode, with a sidebar thread and live transcript. AFK
means unattended end to end: a dispatched run merges its own PR into `epic/<n>`
once it is review-ready, and the epic run keeps picking until every sub-issue is
in. An issue carrying the `hitl` label is a barrier: ship and merge that issue
too, then stop without starting any later issue. A later invocation continues
after the human has handled the checkpoint.

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

In AFK mode, find the first open issue in build order with a case-insensitive
`hitl` label. That issue is the run's horizon: it remains eligible, while every
issue after it is outside this run. Apply the horizon before dispatching anything,
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
tick. In AFK mode, keep polling any PR still open against `epic/<n>`; absence of
a new pick is not a stopping condition while a run is in flight.

## 3. Ship

Before the pick's run starts, prepare its branch and its database.

**Branch.** Create the worktree from the tip of `origin/epic/<n>` on a new
branch. The pick's PR opens with `--base epic/<n>`; name that base to
`ship-issue` — in the invocation for an attended run, in the prompt file for an
AFK one — and it passes it to `gh pr create`.

**Database.** Skip this when no sub-issue of the epic touches the schema or
needs real data. Otherwise every sub-issue of the epic shares one database, so
sub-issue B's migration applies on top of sub-issue A's and an ordering conflict
surfaces while the branch is still open:

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
confirmation. The human merges the sub-issue's PR into `epic/<n>`; the next tick
continues from there.

AFK (the invocation says `afk`): dispatch the pick as its own **t3 thread** via
`scripts/t3-dispatch.sh` — a real sidebar thread with a full live transcript,
where an Agent-tool subagent shows only title and token count. The dispatched
run merges its own PR into `epic/<n>`; the base branch stays the human's.

- Make a fresh worktree of `<repo>` on a new branch, write the run's prompt to
  a file — "Invoke the ship-issue skill with: afk #<n>. This is a ship-epic run:
  open the PR against `epic/<n>` and, once it is review-ready and green, merge it
  there. When it finishes, post the handover report as a comment on issue #<n>,
  as the run's last action." — then:

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

  It prints the created threadId; keep it beside the issue number for the rest
  of the run. First use pairs with the local t3 server and caches a bearer under
  `~/.local/state/ship-issue/`.
- The issue comment is the completion signal and the report channel: poll it
  (and the ledger's `run-end`) at a few-minute interval for the outcome. A pick
  is review-ready only when its full verification and evidence gates passed,
  its Codex review settled with no valid finding left unresolved, and required
  PR checks are green; the run merges on that test and nothing weaker.
- **Settle the thread once its handoff is complete.** When the comment is up and
  the ledger holds the run's `run-end` with `outcome=merged`, clear the thread's
  attention marker:

  ```bash
  scripts/t3-dispatch.sh settle <threadId>
  ```

  The script waits for the thread's turn to end before settling, since a turn
  that ends afterwards re-marks the thread. The marker means "a human must look
  here", and a merged run has nothing left to look at: its report is on the
  issue and its work is in `epic/<n>`. A run that stopped short —
  `outcome=stopped` or `pr-open`, not-AFK-eligible, a failed gate — keeps its
  thread unsettled: the marker is the sidebar's record that it needs a human,
  and its transcript is where they read why.
- Independent picks may run concurrently, **three in flight by default** — a
  run is in flight from dispatch until its issue comment lands. Three is a
  guess, not a measurement: the box also builds and serves, and nothing has yet
  shown where it saturates. Change it in the invocation (`afk 4`) and read the
  ledger's run durations against the overlap before a new number becomes the
  default. A dependent pick waits until its blocker has merged into `epic/<n>`
  before branching. Never dispatch past the AFK run's `hitl` horizon.
- A run that reports not-AFK-eligible (deep tier, unanswerable question) parks
  its sub-issue for an attended tick — never retry it AFK.

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

Route it to a Codex sync session; a human resolving merge hunks is the tick
stalling. Write a prompt from those values: in `<worktree>`, run
`git merge origin/<base>`, resolve each hunk preserving the intent of both sides
(the epic's `## Contracts` says what the epic side meant), run the app's verify
command, then `git push origin HEAD:refs/heads/epic/<n>`. Append `anti-slop.md`
and `handoff.md` from the `ship-issue` skill directory, then:

```bash
<ship-issue>/scripts/run-codex.sh --role sync --issue <epic> --run "$tick" \
  --prompt-file <f> --out <f.last.md> --cd <worktree>
```

Read the handoff. A pushed, verified merge is followed by `sync` again, which
now prints nothing. A handoff that reports both sides changed one contract
incompatibly is an escalation: leave the branch where the script left it and
take it to the human. Only a pushed merge counts — the next `sync` resets the
worktree to what origin holds, so a merge that never reached the remote is
redone, not believed.

A sub-issue PR that opened before a sync is behind `epic/<n>`. That is an
ordinary PR whose base moved: its diff stays its own and CI runs on the merge
result. A conflict there belongs to the sub-issue's run, in a fresh `--role fix`
session before its merge, not to the tick.

## 5. Continue or report

Attended: after handover, loop to step 2 until at most two sub-issues have shipped
this session — past that, context outgrows the tick. Each sub-issue's PR waits
for the human's merge into `epic/<n>`; the next tick continues from what has
landed.

AFK: keep picking and merging. Refresh the survey after each report and dispatch
the next pick until either:

- every sub-issue in the epic has merged into `epic/<n>`, making the complete
  feature ready for the human's review; or
- the `hitl` horizon and every issue before it in build order have merged,
  making that checkpoint ready for the human.

Failures and AFK-ineligible issues still stop the run for human attention;
never step around one to continue the feature.

**The epic PR.** The feature reaches the base branch as one PR, `epic/<n>` into
`<base>`. Sync first (step 4), then open it as a draft when the first sub-issue
merges into the branch, and mark it ready only when every sub-issue has merged:

```bash
gh pr create --base <base> --head epic/<n> --draft --title "<epic title> (#<n>)" --body-file <f>
gh pr ready <pr>
```

Its body holds the epic link and the list of sub-issue PRs merged into the
branch, each linked; refresh that list every tick. The human merges it — the
skill never does. A `hitl` checkpoint leaves it a draft: the human reads the
draft's diff so far, the merged sub-issue PRs, and the status block, then
re-invokes the run; a partial feature never becomes a ready PR.

End every tick by rewriting the epic's status block: the table from step 1,
refreshed — what merged into `epic/<n>`, what is parked for an attended tick,
what waits on the human, what the next tick will pick up — then the branch as
`scripts/epic-branch.sh status` prints it (drift from the base, PRs merged and
open against it, the epic PR), and the epic database with whether this tick
migrated it. Write it to a file and replace the block in the body:

```bash
scripts/epic-status.sh --repo <repo> --epic <n> --file <status.md>
```

It replaces everything between the markers and appends the block on first use, so
the body always holds one current table and never a trail of them. Print the same
table in chat, then close the tick's ledger run:

```bash
<ship-issue>/scripts/ledger.sh event=run-end run="$tick" issue=epic-<n> outcome=tick
```
