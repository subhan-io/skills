---
name: ship-issue
description: Ship one GitHub issue or adhoc task to a finished PR — tiered planning, one fresh Sonnet implementer subagent per chunk, a usage ledger per run.
---

# Ship one issue

One issue in, one finished PR out. The human merges; you never do. Implementer
subagents write all code — you orchestrate, question, plan, and verify.

**Cost is turns × context.** That buys four standing rules:

- Let the implementer read the repo; you read only what a decision in front of
  you requires.
- Make a small change yourself — a typo, a one-line config, a lint fix, a small
  review fix — when it costs less than writing a prompt for it. Send anything
  larger to an implementer: code you read and edit stays in your context for
  every later turn of the run.
- One **fresh** implementer per unit of work: an Agent-tool call with
  `subagent_type: general-purpose` and `model: sonnet` (a model the human names
  replaces it). A continued agent replays its whole history every turn; the one
  sanctioned `SendMessage` continuation is the verify-failure follow-up in step 5.
- Implementers run on `sonnet`, the deep-tier planner (step 4) on `opus`.
  **Never run a subagent or dispatched thread on Fable unless the human explicitly
  asked for Fable on that run.** A Fable loop costs several times an Opus planner,
  and the ledger's model column will show it. Every dispatch names its model in
  chat before it starts, one line, e.g. `Dispatching chunk 2 implementer for #606
  on sonnet`. A dispatch the human cannot see the model of is a dispatch they
  cannot stop in time.

Two human gates, in order: **criteria and tier confirmed** (step 2) and **plan
approved** (step 4). Light work takes them as one: the criteria question carries
the bullet plan, and the answer approves both. No code is written before the plan
is approved. Everything else in this skill is guidance with its reason attached:
follow it unless the work in front of you gives a better reason.

When reality diverges from the plan, stop for the human only if the divergence
changes the scope or the criteria — that decision is theirs. Otherwise adapt, note
the change in `run-state.md`, and report it at handover.

## AFK mode

When the invocation says `afk`, the run is unattended: both gates self-resolve and
the run merges its own PR. The rules that change:

- **Eligibility.** Any tier, when you can state the criteria confidently from
  the issue body and comments. When you cannot, the issue is not AFK-eligible —
  stop and report why instead of guessing. Fail closed.
- **Gate 1**: derive the criteria from the issue; log them in the run-start report
  instead of asking. **Step 3**: an open question with no answer in the issue is an
  eligibility failure, not a guess. **Gate 2**: self-approve the plan (deep tier:
  the Opus planner's plan); a plan that should split becomes a split proposal,
  reported back, never executed. **Step 5**: a `replan` that keeps the scope and
  criteria continues; one that changes either stops the run — report what the
  chunk found.
- **Review**: step 7's rounds apply as written. A valid P0 or P1 from round two
  that a fix cannot clear stops the run unmerged.
- **Merge**: when the last round's fixes are pushed and the PR is green, merge it —
  `gh pr merge <n> --squash --delete-branch` — and log `run-end outcome=merged`.
  Green means the head commit has a GitHub Actions check suite and every required
  check on it passed. An empty check list right after a push means CI has not
  started yet (it can take ten minutes), not that it passed. Anything short of
  green hands over as usual, unmerged.
- The handover report (step 8) still happens in full — it is the only record the
  human gets.
- **Under `ship-epic`** (the launch message says so): the PR opens against the
  epic's integration branch, `epic/<n>`, and the merge above lands there. The
  handover goes up as a comment on the issue after `run-end` and
  `usage-report.sh`. The run's **last action** is the `t3_thread_send` report the
  launch message specifies: it wakes the epic thread, which settles this thread
  on `outcome=merged`. A run that stops short posts the comment and sends the
  report too.

## The ledger

Every run writes usage events to a machine-central ledger
(`~/.local/state/ship-issue/ledger.jsonl`) so a later session can audit what runs
cost: `scripts/usage-report.sh` joins it against the session logs on disk.
None of these writes are skippable:

- `scripts/ledger.sh event=run-start issue=<n> repo=<owner/name> tier=<tier> cwd="$PWD"`
  — at gate 1. It **prints a run id**; keep it and stamp `run=<id>` on every later
  ledger event. The issue must be real (an adhoc slug is fine; `0` or empty is
  rejected). `ledger.sh` records this session's transcript and its model from
  `cwd`; `usage-report.sh` counts every implementer and planner from that
  session's subagent transcripts and shows every model the run used in its
  `cl-models` column.
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
adhoc slug in place of `<n>`): every implementer prompt and handoff, and
`run-state.md`. Outside the repo, so nothing in it can reach the diff; outside
`/tmp`, so it survives a reboot.

**`run-state.md` is the run's scratchpad. Rewrite it whole after every step**; an
appended log goes stale while a rewritten page stays true. A resumed session, and
every implementer, reads it as the truth about where the run is. It holds,
in this order:

- run id, issue, tier, the confirmed criteria, the settled decisions, and the epic
  context block when there is one;
- the current step and, during step 5, the next chunk;
- the branch, the last verified HEAD, the PR number, and the review round;
- **Repo now**: the tree as it stands after the last verified implementer — interfaces
  introduced, helpers to reuse, files shaped differently from the plan — merged from
  each handoff's *For the next session*. Fold new facts in and drop superseded ones,
  so the section describes the tree, not its history.

An implementer writes its handoff to the path its prompt names and returns the
same text as its final message. An implementer gets the path of `run-state.md`
and the path of the previous implementer's handoff, and nothing older: the
scratchpad already carries the earlier implementers' facts, so an older handoff
adds cost without adding truth.

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
after this one, and every implementer prompt carries the block under an `Epic context`
heading. When `ship-epic` invoked this run it hands you the block; use it as given.
An epic without `## Contracts` gets one the moment this run settles an interface a
later sub-issue depends on: append it to the parent body.

**Repo notes.** If `<repo>/.claude/ship-issue/repo-notes.md` exists, read it and paste
it into every implementer prompt under a `Repo notes` heading. It is what earlier runs
learned about this repository the hard way (step 6 is where a run adds to it).

If the task may change anything a user sees, load the complete `ui-evidence`
skill now through the harness's skill mechanism. A reference to its name is not
the contract. If the harness cannot invoke it, read its installed `SKILL.md` in
full; if neither route is available, stop before the criteria gate. Keep its
capture routes and completion test live for the rest of the run.

## 2. Confirm criteria and tier — gate

Draft the acceptance criteria as a short checklist, pick the tier, and put both
to the human in one AskUserQuestion: are these the criteria, and is this the right
tier? For light work, add the bullet plan to the same question; its answer is
also gate 2, and the run goes to step 5. Their answer is the definition of
finished for the whole run. Log `run-start` and keep the run id it prints for
every later ledger write; for light work, log `phase=plan-approved` after it.

The tier sets how much planning the work gets. Judge it from how hard the design
is to get right; the examples below are signals, not thresholds.

| tier | typical shape | planning |
|---|---|---|
| **light** | a small, contained change; no schema or auth change, no UI redesign | bullet plan in the criteria question |
| **standard** | most work | plan inline this session; `plan-explainer` page only when a mock or a fork benefits from being seen |
| **deep** | the design is hard to get right: a schema migration, auth/payments/data deletion, work across app boundaries, a new subsystem | dispatch the Plan agent, `model: opus` |

## 3. Resolve open questions

Iterate with the human until no decision that shapes the plan is still open. The
human is a visual learner — show, don't describe: small forks go through
AskUserQuestion; anything visual, or needing more context than a question box
carries, goes through the `plan-explainer` skill.

## 4. Plan → present — gate (standard and deep)

Split the work into chunks an implementer can finish with room to spare in its
context; a small change is one chunk. Every chunk states the files/areas it
touches, its deliverable, and a verify command that proves the chunk landed:
the checks relevant to what it touched. The full CI check set runs once, in
step 6.

**Propose a split when the parts ship independently and one PR would be too
large to review well**; a long plan that does not divide that way runs as one PR.
Draft sub-issues along the plan's seams — each independently shippable and
verifiable, criteria carried verbatim plus a "criteria and approach approved in
the #<n> split" note — and present the split at this gate instead. On approval: create the children, mark
any the human wants an interactive pass on, rewrite the parent into a tracker (one-
paragraph goal plus a task list of children, with the build order stated). Then
ship the first child in this session as its own run; the
`ship-epic` skill drains the rest. Log the parent's run-end as `outcome=split`.

Deep tier: dispatch the Plan agent (`model: opus`) with the issue, the confirmed
criteria, the settled decisions, and file pointers — a tight prompt, not an
invitation to wander the repo. Log `event=phase phase=planner-done` when it
returns. You turn its plan into the presentation.

Present the plan (`plan-explainer` when it earns it, inline otherwise) and wait
for explicit approval. Approval of the plan is
not approval of scope changes discovered later — those come back to the human. On
approval, log `event=phase phase=plan-approved`.

## 5. Implement — one fresh implementer per chunk

For each chunk, in order, write the prompt to `chunk-<i>.prompt.md` in the run
directory: the chunk's spec, its criteria, its verify command, the epic context and
repo notes when they exist, the path of `run-state.md`, the path of the previous
implementer's handoff, and the path this one writes its handoff to
(`chunk-<i>.handoff.md`). Always append `anti-slop.md` then `handoff.md` (both in
this skill's directory) with `cat >>`, not by retyping them; `handoff.md` fixes the
shape of the final message you act on.
For a chunk touching anything a user sees, paste the complete loaded
`ui-evidence` content into the prompt under a `UI evidence contract` heading and
make published screenshots part of the deliverable. Do not launch a UI chunk
whose prompt merely names or links the skill. A worker's evidence report is an
input to the final gate; the orchestrator still owns that gate.

Write the ownership split into every prompt: the implementer works in `<repo>`
and runs every check that gates its chunk — typecheck, unit tests, lint,
docker-backed suites — and reports their output; the commit stays yours, so tell
it to leave all changes unstaged for you to commit. Do not mention the ledger in a
prompt: a session told about it once refused to work until it could write there.
Then dispatch it with the Agent tool, in the background:

- `subagent_type: general-purpose`, `model: sonnet`,
  `description: "chunk <i> #<n>"`;
- `prompt`: "Your task is in `<run dir>/chunk-<i>.prompt.md`. Read it in full,
  then do it."

The prompt file keeps the spec out of your own output and on disk for the record.
Its final message is the handoff. Then run the chunk's verify command yourself. On
failure, log `event=phase phase=verify-failed chunk=<i>` and send the failure
output back with `SendMessage` to that agent. Keep fixing while each attempt
makes progress; when an agent's context has grown heavy, a fresh implementer with
the failure evidence inline is cheaper. Stop and report when attempts repeat the
same failure. A chunk is done only when its verify command passes in your shell.

A green chunk still steers the plan. Read its handoff's *Remaining plan impact*
before anything else runs:

- `none` → rewrite `run-state.md`; start the next chunk.
- `adjust` → fold the change into *Repo now* and into the next chunk's spec, and
  say so in `run-state.md`. Scope and criteria stand, so no gate reopens.
- `replan` → the remaining chunks are void. Re-plan them from the tree as it is
  (deep tier: re-dispatch the Plan agent with the handoff and `run-state.md`). A new
  plan that keeps the approved scope and criteria continues once it is in
  `run-state.md`; one that changes either is a new gate 2 and goes to the human.

## 6. Full test pass, evidence gate, then the PR

Run the repo's full test suite and every check the touched apps' CI runs —
read the workflow files, do not assume lint, typecheck and test cover them. A
check that CI runs and this pass skips fails only after the PR opens (#553: a
separate `lint:anti-slop` gate caught 52 warnings that three chunks and two
review rounds missed). Fix small failures yourself; send larger ones to fresh fix
implementers, until green.

Create the branch and commit the product changes, then record
`git rev-parse HEAD`; UI evidence must render that commit. A temporary
uncommitted harness may sit on top of it only as allowed by `ui-evidence`, and
must be removed before push.

For every user-visible change, load `pr-media-upload` and run the capture
yourself, even when a chunk returned candidate shots. The result is the evidence
report `ui-evidence` defines, for the recorded HEAD. A report missing a field is an
incomplete gate: continue capture or stop the run.

Before the PR, harvest the handoffs' *Repo gotchas*. A fact a future run should
know goes into `<repo>/.claude/ship-issue/repo-notes.md`, folded into the section
it belongs to — the file is a reference, not a log: merge, and delete an entry this
run proved stale. Create the file with the first fact. Commit that change on the
branch by itself and name it in the PR body; a gotcha that surfaces later in a
review-fix implementer rides that round's commit.

After the evidence gate, verify that cleanup returned the tree to the recorded
HEAD, then push and run `gh pr create` — with `--base epic/<n>` when `ship-epic`
named an integration branch. The body contains the issue link, confirmed
criteria checklist, chunk summary and the evidence report. The PR is not open
until this gate is complete. When the `t3-code` MCP server exposes
`link_pull_request`, link the PR to this thread right after creating it, so the
sidebar tracks its checks and merge.

## 7. Review — two rounds at most

Before requesting anything: run the repo's lint and anti-slop checks yourself and
reread the diff against `anti-slop.md` — every finding you catch here is a review
round you don't pay for.

Then log `event=phase phase=review-requested round=<n>`, run one round with the
`codex-review` skill, and log `phase=review-settled round=<n>` when it lands.
Triage its findings yourself: decide each from the code it points at, not from
the finding's confidence. Which valid findings you fix depends on the round and
the finding's Codex priority (`priority` in the `findings` output):

- **Round 1**: fix valid P0, P1 and P2 findings.
- **Round 2** runs only when round 1 pushed fixes. Fix valid P0 and P1 findings.
- **No round 3.** Push round 2's fixes and hand over without requesting another
  review.

Fix small findings yourself; the rest go to one **fresh** review-fix implementer
for the round — never a `SendMessage` to a chunk's agent; push, and refresh
any shots the fixes changed. Every finding you do not fix gets a reply tagged
`(resolver, round N)`: the evidence for an invalid one, or "deferred: P<n>" for a
valid one below the round's bar. Deferred findings go in the handover report.

A valid finding that states a rule for the whole repo, not a one-off bug, goes into
`repo-notes.md` in the round's fix commit, worded as the rule: "a worker job can be
delivered twice, so its side effects must be idempotent", not "fixed double insert
in apify.ts". Every later chunk prompt carries the notes, so the implementer meets
the rule before review has to.

## 8. Hand over

Report to the human: the PR URL, the criteria checklist with each item's status,
test status, review outcomes, and anything open. Log `run-end`, then run
`scripts/usage-report.sh --run <id>` and add its friction line to the report:
implementers that failed or returned no handoff, verify failures, review rounds,
and findings. A
number that recurs across runs is a defect in a prompt or a script, not bad luck —
name it when you see it, with the ledger row that shows it. Under `ship-epic`, the
same report is the issue comment described in AFK mode, posted last. Never merge —
the human does.
