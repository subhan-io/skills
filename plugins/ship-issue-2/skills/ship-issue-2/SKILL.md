---
name: ship-issue-2
description: Ship one GitHub issue or adhoc task to a finished PR — Codex implements every chunk.
disable-model-invocation: true
---

# Ship one issue (v2, Codex-only)

One issue in, one finished PR out. The human merges; you never do. Codex writes all
code — you orchestrate, question, plan, and verify. Keep your own context lean: let
Codex read the repo; you read only what a decision in front of you requires.

Two hard gates, in order: **criteria confirmed** (step 2) and **plan approved**
(step 5). No code is written before both.

If a step fails or reality diverges from the plan, stop and report to the human with
what you saw. Resume only on their answer.

## 1. Read the task

- A GitHub issue URL/number: `gh issue view <n> --comments`.
- Otherwise treat the message as an adhoc task; restate it in one paragraph.

One issue per run. If the task bundles several, ask which one to ship first.

## 2. Confirm what "finished" means

Draft the acceptance criteria as a short checklist and confirm them with the human
via AskUserQuestion before any planning. Done when the human has explicitly agreed
to a criteria list; that list is the definition of finished for the whole run.

## 3. Resolve open questions

Iterate with the human until no decision that shapes the plan is still open. The
human is a visual learner — show, don't describe:

- Small forks → AskUserQuestion.
- Anything visual, or needing more context than a question box carries → build an
  HTML page from `explainer-skeleton.html` (UI mocks from the app's real design
  tokens, flow diagrams, options as selectable cards with an optional note per
  question, sticky one-line "Copy answers" button that copies questions + answers
  as plain text). Upload with the `pr-media-upload` skill and give the human the
  URL; they paste answers back here.

Page prose is ASD-STE100 Simplified Technical English: one idea per sentence, under
20 words, active voice, same word for the same thing. No repo tour — the human knows
the stack; write only about what changes.

## 4. Chunk the plan

Split the work into sequential chunks, each sized so a single Codex session stays
inside ~150–200k tokens — the model's effective intelligence window. Every chunk
states:

- the files/areas it touches,
- its deliverable,
- a verify command (test, build, or script) that proves the chunk landed.

## 5. Present the plan — hard stop

Present the chunked plan (as an explainer page when it benefits from mocks, inline
otherwise) and wait for explicit approval. Approval of the plan is not approval of
scope changes discovered later — those come back to the human.

## 6. Implement — Codex only

Dispatch the `codex:codex-rescue` agent once per chunk, sequentially, with
`run_in_background: false`. Draft each prompt with the `codex:gpt-5-4-prompting`
skill: the chunk's spec, its acceptance criteria, and its verify command. For a
chunk touching user-visible code, append `screenshots.md` (in this skill's
directory) to the prompt — screenshots are part of that chunk's deliverable.

- Chunk 1: fresh Codex run.
- Every later chunk: include `--resume` so Codex reuses the same session — its repo
  context is already warm; do not re-explain what earlier chunks established.

After each chunk, run its verify command yourself. Failures go back to Codex with
`--resume`; a chunk is done only when its verify command passes.

## 7. Full test pass

Run the repo's full test suite. Send any failure to Codex (`--resume`) until the
suite is green.

## 8. Open the PR

Branch, commit, push, `gh pr create`. Body: the issue link, the confirmed criteria
as a checklist, the chunk summary, and — whenever any part of the change is
user-visible — embedded screenshots (`![alt](url)`; video as a
`<video src="url" controls width="640">` tag on its own line).

The PR is not open-and-done until every user-visible change is either pictured in
the body or carries its `un-capturable:` reason from `screenshots.md`. A UI chunk
whose report came back with neither goes back to Codex for capture before the PR
opens — the reviewer never has to guess whether shots were skipped or impossible.
Later pushes that change the UI (review fixes included) refresh the body's shots.

## 9. Codex review loop — twice

Codex is not a GitHub check — nothing in `gh pr checks` reflects it. Drive it with
`scripts/codex-wait.sh` (in this skill's directory), which knows the completion
signal: the bot has covered the head commit *and* gone quiet for the settle window.

Run this loop two times:

1. `scripts/codex-wait.sh request <pr>` — posts the `@codex review` trigger.
2. `scripts/codex-wait.sh watch <pr>` — blocks until settled; **always run it as a
   background command**, never in a foreground poll loop. On timeout (exit 4),
   check `status` and keep waiting rather than reading early: an `arriving` review
   is a truncated finding set.
3. `scripts/codex-wait.sh findings <pr>` — the head commit's findings with
   severity, staleness and reply counts. Branch on `resolverReplyCount` /
   `counts.unresolved`, not `replyCount` — conversation in a thread is not
   resolution.
4. Triage: fix valid findings via a Codex `--resume` dispatch and push; answer
   invalid ones with a reply comment tagged `(resolver, round N)` explaining why —
   that marker is what the script counts as resolved.

The loop iteration is done when `counts.unresolved` is zero for the head commit.

## 10. Hand over

Report to the human: the PR URL, the criteria checklist with each item's status,
test status, and both review rounds' outcomes. Never merge — the human does.
