---
name: ship-issue
description: Ship one GitHub issue or adhoc task to a finished PR — tiered planning, one fresh Codex session per chunk, a usage ledger per run.
---

# Ship one issue

One issue in, one finished PR out. The human merges; you never do. Codex writes all
code — you orchestrate, question, plan, and verify.

**Cost on both subscriptions is turns × context.** That buys three standing rules:

- Let Codex read the repo; you read only what a decision in front of you requires,
  and batch independent tool calls into one message.
- One **fresh** Codex session per unit of work, through `scripts/run-codex.sh`. A
  resumed session replays its whole history every turn; the one sanctioned resume is
  the single follow-up in step 5.
- The deep-tier planner (step 4) is the only subagent this skill dispatches, on
  `model: opus`. **Never run a subagent or dispatched thread on Fable unless the
  human explicitly asked for Fable on that run.** A Fable orchestrator loop costs
  several times an Opus planner, and the ledger's model column will show it.
  Every dispatch names its model in chat before it starts, one line, e.g.
  `Dispatching Plan agent for #606 on opus`. A dispatch the human cannot see the
  model of is a dispatch they cannot stop in time.

Two hard gates, in order: **criteria and tier confirmed** (step 2) and **plan
approved** (step 4). No code is written before both.

If a step fails or reality diverges from the plan, stop and report to the human with
what you saw. Resume only on their answer.

## AFK mode

When the invocation says `afk`, the run is unattended: both gates self-resolve and
the run merges its own PR. The rules that change:

- **Eligibility.** Light and standard tiers only. A deep-tier issue, or one whose
  criteria you cannot state confidently from the issue body and comments, is not
  AFK-eligible — stop and report why instead of guessing. Fail closed.
- **Gate 1**: derive the criteria from the issue; log them in the run-start report
  instead of asking. **Step 3**: an open question with no answer in the issue is an
  eligibility failure, not a guess. **Gate 2**: self-approve the plan; a plan past
  2 chunks still becomes a split proposal, reported back, never executed.
  **Step 5**: a handoff that says `replan` stops the run — fail closed, report what
  the chunk found.
- **Merge**: after the review round settles and the PR is green, merge it —
  `gh pr merge <n> --squash --delete-branch` — and log `run-end outcome=merged`.
  Anything short of green hands over as usual, unmerged.
- The handover report (step 8) still happens in full — it is the only record the
  human gets.
- **Under `ship-epic`** (the dispatch prompt says so): the PR opens against the
  epic's integration branch, `epic/<n>`, and the merge above lands there. The base
  branch is the human's, reached once by the epic's own PR. The handover goes up
  as a comment on the issue, and it is the run's **last action**: after `run-end`
  and `usage-report.sh`, so it carries the friction line, and followed only by
  the same report in chat — no question, no further work. That comment is
  `ship-epic`'s completion signal: on it the tick reads the outcome and settles
  this thread, so anything the run does after posting happens in a thread already
  marked done. A run that stops short posts the comment too, with what it found;
  its thread stays unsettled for the human.

## The ledger

Every run writes usage events to a machine-central ledger
(`~/.local/state/ship-issue/ledger.jsonl`) so a later session can audit what runs
cost: `scripts/usage-report.sh` joins it against both harnesses' session logs.
None of these writes are skippable:

- `scripts/ledger.sh event=run-start issue=<n> repo=<owner/name> tier=<tier> cwd="$PWD"`
  — at gate 1. It **prints a run id**; keep it and stamp `run=<id>` on every later
  ledger event and `--run <id>` on every `run-codex.sh` call. The issue must be
  real (an adhoc slug is fine; `0` or empty is rejected). `ledger.sh` records this
  session's transcript and its model from `cwd`; `usage-report.sh` shows every
  model the run used, subagents included, in its `cl-models` column.
- `scripts/run-codex.sh` appends its own event per Codex session.
- Phase events, so cost can be attributed per step:
  `event=phase phase=plan-approved` at gate 2; `phase=planner-done` when a deep-tier
  Plan agent returns (its Opus cost is invisible to the ledger otherwise);
  `phase=verify-failed chunk=<i>` on each failed chunk verify;
  `phase=review-requested round=<n>` and `phase=review-settled round=<n>` around
  each review round. Always with `run=<id> issue=<n>`. `ledger.sh` rejects phase
  names outside this set — an event it refuses is a step this skill doesn't have.
- `scripts/ledger.sh event=run-end run=<id> issue=<n> outcome=<pr-open|merged|stopped|split>
  pr=<n> chunks=<n> reviewRounds=<n> findingsValid=<n> findingsInvalid=<n>
  verifyRetries=<n>` — when you hand over or stop.

## The run directory

Every run keeps its working files in `~/.local/state/ship-issue/issue-<n>/` (the
adhoc slug in place of `<n>`): every Codex prompt and `--out` file, and
`run-state.md`. Outside the repo, so nothing in it can reach the diff; outside
`/tmp`, so it survives a reboot.

**`run-state.md` is the run's scratchpad. Rewrite it whole after every step**; an
appended log goes stale while a rewritten page stays true. A resumed session, and
every later Codex session, reads it as the truth about where the run is. It holds,
in this order:

- run id, issue, tier, the confirmed criteria, the settled decisions, and the epic
  context block when there is one;
- the current step and, during step 5, the next chunk;
- the branch, the last verified HEAD, the PR number, and the review round;
- **Repo now**: the tree as it stands after the last verified session — interfaces
  introduced, helpers to reuse, files shaped differently from the plan — merged from
  each handoff's *For the next session*. Fold new facts in and drop superseded ones,
  so the section describes the tree, not its history.

A session's handoff is its `--out` file. A Codex session gets the path of
`run-state.md` and the path of the previous session's handoff, and nothing older: the scratchpad already carries the earlier
sessions' facts, so an older handoff adds cost without adding truth.

## 1. Read the task

- A GitHub issue URL/number: `gh issue view <n> --comments`.
- Otherwise treat the message as an adhoc task; restate it in one paragraph.

One issue per run. If the task bundles several, ask which one to ship first.

**Epic context.** An issue with a parent is a sub-issue of an epic:

```bash
gh api graphql -f query='query{repository(owner:"<o>",name:"<r>"){issue(number:<n>){
  parent{number title}}}}'
```

Read the parent too. Its goal, build order, `## Contracts` section, and the states of
its other sub-issues are the epic context: the plan must compose with the sub-issues
after this one, and every Codex prompt carries the block under an `Epic context`
heading. When `ship-epic` invoked this run it hands you the block; use it as given.
An epic without `## Contracts` gets one the moment this run settles an interface a
later sub-issue depends on: append it to the parent body.

**Repo notes.** If `<repo>/.claude/ship-issue/repo-notes.md` exists, read it and paste
it into every Codex prompt under a `Repo notes` heading. It is what earlier runs
learned about this repository the hard way (step 6 is where a run adds to it).

If the task may change anything a user sees, load the complete `ui-evidence`
skill now through the harness's skill mechanism. A reference to its name is not
the contract. If the harness cannot invoke it, read its installed `SKILL.md` in
full; if neither route is available, stop before the criteria gate. Keep its
capture routes and completion test live for the rest of the run.

## 2. Confirm criteria and tier — gate

Draft the acceptance criteria as a short checklist, pick the tier from the table,
and put both to the human in one AskUserQuestion: are these the criteria, and is
this the right tier? Their answer is the definition of finished for the whole run.
Log `run-start` and keep the run id it prints for every later ledger write and
`run-codex.sh --run`.

| tier | when | planning |
|---|---|---|
| **light** | ≤ ~3 files expected, no schema/auth change, no UI redesign | bullet plan in chat, this session writes it |
| **standard** | everything else | plan inline this session; `plan-explainer` page only when a mock or a fork benefits from being seen |
| **deep** | ≥2 of: schema migration · auth/payments/data-deletion · crosses app boundaries · > ~10 files expected · new subsystem | dispatch the Plan agent, `model: opus` |

## 3. Resolve open questions

Iterate with the human until no decision that shapes the plan is still open. The
human is a visual learner — show, don't describe: small forks go through
AskUserQuestion; anything visual, or needing more context than a question box
carries, goes through the `plan-explainer` skill.

## 4. Plan → present — gate

Split the work into sequential chunks, each sized so a single Codex session stays
inside ~150–200k tokens. Every chunk states the files/areas it touches, its
deliverable, and a verify command that proves the chunk landed.

**A plan of more than 2 chunks is a split proposal, not a plan.** Draft sub-issues
along the plan's seams — each independently shippable and verifiable, criteria
carried verbatim plus a "criteria and approach approved in the #<n> split" note —
and present the split at this gate instead. On approval: create the children, mark
any the human wants an interactive pass on, rewrite the parent into a tracker (one-
paragraph goal plus a task list of children, with the build order stated). Then
ship the first child in this session as its own light/standard run; the
`ship-epic` skill drains the rest. Log the parent's run-end as `outcome=split`.

Deep tier: dispatch the Plan agent (`model: opus`) with the issue, the confirmed
criteria, the settled decisions, and file pointers — a tight prompt, not an
invitation to wander the repo. Log `event=phase phase=planner-done` when it
returns. You turn its plan into the presentation.

Present per tier (light: the bullet list; standard/deep: `plan-explainer` when it
earns it, inline otherwise) and wait for explicit approval. Approval of the plan is
not approval of scope changes discovered later — those come back to the human. On
approval, log `event=phase phase=plan-approved`.

## 5. Implement — one fresh Codex session per chunk

For each chunk, in order: draft the prompt with the `codex:gpt-5-4-prompting`
skill — the chunk's spec, its criteria, its verify command, the epic context and
repo notes when they exist, the path of `run-state.md` and of the previous session's
handoff — and always append `anti-slop.md` then `handoff.md` (both in this skill's
directory). `handoff.md` fixes the shape of the session's final message; the
orchestrator reads that message, so a prompt without it produces a summary you
cannot act on.
For a chunk touching anything a user sees, paste the complete loaded
`ui-evidence` content into the prompt under a `UI evidence contract` heading and
make published screenshots part of the deliverable. Do not launch a UI chunk
whose prompt merely names or links the skill. A worker's evidence report is an
input to the final gate; the orchestrator still owns that gate.

Write the ownership split into every prompt: Codex runs with full access, so it
runs every check that gates its chunk — typecheck, unit tests, lint, docker-backed
suites — and reports their output; the commit and the ledger stay yours, so tell
it to leave all changes unstaged for you to commit. Then:

```bash
scripts/run-codex.sh --role chunk --issue <n> --index <i> --run <runId> \
  --prompt-file <f> --out <chunk-i.last.md> --cd <repo>
```

Run it backgrounded; read `--out` when it finishes. Then run the chunk's verify
command yourself. On failure, log `event=phase phase=verify-failed chunk=<i>` and
send the failure output back once with `--resume <sessionId>`; if it is still red
after that, run one fresh session with the failure evidence inline; still red →
stop and report. A chunk is done only when its verify command passes in your shell.

A green chunk still steers the plan. Read its handoff's *Remaining plan impact*
before anything else runs:

- `none` → rewrite `run-state.md`; start the next chunk.
- `adjust` → fold the change into *Repo now* and into the next chunk's spec, and
  say so in `run-state.md`. Scope and criteria stand, so no gate reopens.
- `replan` → the remaining chunks are void. Re-plan them from the tree as it is
  (deep tier: re-dispatch the Plan agent with the handoff and `run-state.md`). A new
  plan that keeps the approved scope and criteria continues once it is in
  `run-state.md`; one that changes either is a new gate 2 and goes to the human.

Planning does not end at gate 2: each handoff is the planner's next input, and a
plan that never moves after the first chunk was never checked against the code.

## 6. Full test pass, evidence gate, then the PR

Run the repo's full test suite; failures go back to Codex as fresh `--role fix`
sessions until green. Create the branch and commit the product changes, then
record `git rev-parse HEAD`; UI evidence must render that commit. A temporary
uncommitted harness may sit on top of it only as allowed by `ui-evidence`, and
must be removed before push.

For every user-visible change, reload the complete `ui-evidence` skill immediately
before capture and load `pr-media-upload`. The orchestrator executes the capture
itself even when a chunk returned candidate shots. Its evidence report must name:

- the captured HEAD;
- the real-route result, including the preview command's reported database mode
  and the observed application-auth result;
- the sanctioned scratch-data route result or its precise unavailability;
- the production-shell fixture-harness result or why it would render inaccurate
  pixels;
- the published URLs, or an `un-capturable:` conclusion supported by all three
  route results.

Resolve contradictions from command and browser output before completing the
report; a conversational guess about the database is not evidence. Component,
integration and end-to-end tests support behavioral claims but never substitute
for visible pixels. An `un-capturable:` conclusion that omits a route is an
incomplete gate, so continue capture or stop the run.

Before the PR, harvest the handoffs' *Repo gotchas*. A fact a future run should
know goes into `<repo>/.claude/ship-issue/repo-notes.md`, folded into the section
it belongs to — the file is a reference, not a log: merge, and delete an entry this
run proved stale. Create the file with the first fact. Commit that change on the
branch by itself and name it in the PR body; a gotcha that surfaces later in a
review-fix session rides that round's commit.

After the evidence gate, verify that cleanup returned the tree to the recorded
HEAD, then push and run `gh pr create` — with `--base epic/<n>` when `ship-epic`
named an integration branch. The body contains the issue link, confirmed
criteria checklist, chunk summary and the evidence report. The PR is not open
until this gate is complete.

## 7. Review — one round, two max

Before requesting anything: run the repo's lint and anti-slop checks yourself and
reread the diff against `anti-slop.md` — every finding you catch here is a review
round you don't pay for. Findings the reviewer would raise are cheapest fixed
before it ever looks.

Then log `event=phase phase=review-requested round=<n>`, run one round with the
`codex-review` skill, and log `phase=review-settled round=<n>` when it lands.
Triage its findings yourself — read the code each one points at and decide from
the code, not the finding's confidence; a triage that waves everything through is
a rubber stamp, and some findings *are* wrong. Valid ones go to a **fresh**
`run-codex.sh --role review-fix` session — never `--resume` the chunk session for
review fixes (one fresh session covers the round's fixes), push, and refresh any
shots the fixes changed; invalid ones get a reply tagged `(resolver, round N)`
with the evidence. A second round runs only for
deep tier, or when round one produced a fix that changed behavior. At two rounds,
stop and hand over what is outstanding.

## 8. Hand over

Report to the human: the PR URL, the criteria checklist with each item's status,
test status, review outcomes, and anything open. Log `run-end`, then run
`scripts/usage-report.sh --run <id>` and add its friction line to the report: Codex
sessions that exited non-zero, verify failures, review rounds, and findings. A
number that recurs across runs is a defect in a prompt or a script, not bad luck —
name it when you see it, with the ledger row that shows it. Under `ship-epic`, the
same report is the issue comment described in AFK mode, posted last. Never merge —
the human does.

## Under the Codex harness

The native Codex plugin exposes this skill as `/ship-issue`. The same steps
apply, with three adaptations:

- Where a step says AskUserQuestion, ask as a short numbered list in plain text and
  wait for the reply.
- Where a step backgrounds `codex-wait.sh watch`, poll `codex-wait.sh status <pr>`
  at a few-minute interval instead.
- Chunks still run as separate sessions through `scripts/run-codex.sh` — the
  orchestrating session's own turn count and context stay small, and the ledger
  stays per-chunk.

The companion skills (`plan-explainer`, `ui-evidence`, `codex-review`,
`pr-media-upload`) are fellow plugins from this marketplace; where the harness does
not surface one as an invocable skill, read its `SKILL.md` from the installed
plugin and follow it directly.
