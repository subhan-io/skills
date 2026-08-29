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
- The deep-tier planner (step 4) is the only subagent this skill dispatches.

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
- **Merge**: after the review round settles and the PR is green, merge it —
  `gh pr merge <n> --squash --delete-branch` — and log `run-end outcome=merged`.
  Anything short of green hands over as usual, unmerged.
- The handover report (step 8) still happens in full — it is the only record the
  human gets.

## The ledger

Every run writes usage events to a machine-central ledger
(`~/.local/state/ship-issue/ledger.jsonl`) so a later session can audit what runs
cost: `scripts/usage-report.sh` joins it against both harnesses' session logs.
None of these writes are skippable:

- `scripts/ledger.sh event=run-start issue=<n> repo=<owner/name> tier=<tier> cwd="$PWD"`
  — at gate 1. It **prints a run id**; keep it and stamp `run=<id>` on every later
  ledger event and `--run <id>` on every `run-codex.sh` call. The issue must be
  real (an adhoc slug is fine; `0` or empty is rejected).
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

## 1. Read the task

- A GitHub issue URL/number: `gh issue view <n> --comments`.
- Otherwise treat the message as an adhoc task; restate it in one paragraph.

One issue per run. If the task bundles several, ask which one to ship first.

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
skill — the chunk's spec, its criteria, its verify command, the paths of previous
chunks' summaries — and always append `anti-slop.md` (in this skill's directory);
for a chunk touching anything a user sees, also append the `ui-evidence` skill's
content, making screenshots part of the deliverable.

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

## 6. Full test pass, then the PR

Run the repo's full test suite; failures go back to Codex as fresh `--role fix`
sessions until green. Then branch, commit, push, `gh pr create`. Body: the issue
link, the confirmed criteria as a checklist, the chunk summary, and — whenever any
part of the change is user-visible — the published shots per `ui-evidence`
(including any `un-capturable:` reasons). The PR is not open until every
user-visible change is pictured or carries its reason.

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
test status, review outcomes, and anything open. Log `run-end`. Never merge — the
human does.

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
