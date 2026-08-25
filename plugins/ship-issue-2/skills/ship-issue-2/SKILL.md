---
name: ship-issue-2
description: Ship one GitHub issue or adhoc task to a finished PR — tiered planning, one fresh Codex session per chunk, a usage ledger per run.
disable-model-invocation: true
---

# Ship one issue (v2)

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

## The ledger

Every run writes usage events to a machine-central ledger
(`~/.local/state/ship-issue/ledger.jsonl`) so a later session can audit what runs
cost: `scripts/usage-report.sh` joins it against both harnesses' session logs.
Three writes per run, none skippable:

- `scripts/ledger.sh event=run-start issue=<n> repo=<owner/name> tier=<tier> cwd="$PWD"` — at gate 1.
- `scripts/run-codex.sh` appends its own event per Codex session.
- `scripts/ledger.sh event=run-end issue=<n> outcome=<pr-open|stopped|split> pr=<n> chunks=<n> reviewRounds=<n>` — when you hand over or stop.

## 1. Read the task

- A GitHub issue URL/number: `gh issue view <n> --comments`.
- Otherwise treat the message as an adhoc task; restate it in one paragraph.

One issue per run. If the task bundles several, ask which one to ship first.

## 2. Confirm criteria and tier — gate

Draft the acceptance criteria as a short checklist, pick the tier from the table,
and put both to the human in one AskUserQuestion: are these the criteria, and is
this the right tier? Their answer is the definition of finished for the whole run.
Log `run-start`.

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
paragraph goal plus a task list of children; move `ready-for-agent` off the parent
and onto unblocked children — the dispatcher must never pick up the parent). Then
ship the first child in this session as its own light/standard run; `dispatch-agents`
drains the rest. Log the parent's run-end as `outcome=split`.

Deep tier: dispatch the Plan agent (`model: opus`) with the issue, the confirmed
criteria, the settled decisions, and file pointers — a tight prompt, not an
invitation to wander the repo. You turn its plan into the presentation.

Present per tier (light: the bullet list; standard/deep: `plan-explainer` when it
earns it, inline otherwise) and wait for explicit approval. Approval of the plan is
not approval of scope changes discovered later — those come back to the human.

## 5. Implement — one fresh Codex session per chunk

For each chunk, in order: draft the prompt with the `codex:gpt-5-4-prompting`
skill — the chunk's spec, its criteria, its verify command, the paths of previous
chunks' summaries — and always append `anti-slop.md` (in this skill's directory);
for a chunk touching anything a user sees, also append the `ui-evidence` skill's
content, making screenshots part of the deliverable. Then:

```bash
scripts/run-codex.sh --role chunk --issue <n> --index <i> \
  --prompt-file <f> --out <chunk-i.last.md> --cd <repo>
```

Run it backgrounded; read `--out` when it finishes. Then run the chunk's verify
command yourself. On failure, send the failure output back once with
`--resume <sessionId>`; if it is still red after that, run one fresh session with
the failure evidence inline; still red → stop and report. A chunk is done only when
its verify command passes in your shell.

## 6. Full test pass, then the PR

Run the repo's full test suite; failures go back to Codex as fresh `--role fix`
sessions until green. Then branch, commit, push, `gh pr create`. Body: the issue
link, the confirmed criteria as a checklist, the chunk summary, and — whenever any
part of the change is user-visible — the published shots per `ui-evidence`
(including any `un-capturable:` reasons). The PR is not open until every
user-visible change is pictured or carries its reason.

## 7. Review — one round, two max

Run one round with the `codex-review` skill. Triage its findings yourself: valid
ones go to a fresh `run-codex.sh --role review-fix` session (one session covers the
round's fixes), push, and refresh any shots the fixes changed; invalid ones get a
reply tagged `(resolver, round N)` with the evidence. A second round runs only for
deep tier, or when round one produced a fix that changed behavior. At two rounds,
stop and hand over what is outstanding.

## 8. Hand over

Report to the human: the PR URL, the criteria checklist with each item's status,
test status, review outcomes, and anything open. Log `run-end`. Never merge — the
human does.
