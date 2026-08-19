You are planning the implementation of GitHub issue **#{{ISSUE_NUMBER}}** in `{{REPO}}`.

**{{ISSUE_TITLE}}**
{{ISSUE_URL}}

```
{{ISSUE_BODY}}
```

Work in the worktree `{{WORKTREE}}` (branch `{{BRANCH}}`, cut from `origin/{{BASE_BRANCH}}`).
You are planning only — **write no implementation code and push nothing.** The one file you
write is the explainer described below, and it goes in the run's state directory
`{{STATE_DIR}}`, which sits beside the worktree, not inside it.

The skill driving this run lives at `{{SKILL_DIR}}`; the explainer skeleton is read from there.

Detected toolchain (verify before relying on it; the detection reads manifests, not reality):
- install: `{{INSTALL_CMD}}`
- test: `{{TEST_CMD}}`
- typecheck: `{{TYPECHECK_CMD}}`
- lint: `{{LINT_CMD}}`

## What to produce

Read the code before planning it. A plan derived from the issue text alone is a guess: open the
files that will change, find the existing patterns the change should follow, and note the tests
that already cover the area. Where the issue is ambiguous, say so explicitly rather than
resolving it silently — a flagged ambiguity is what the approval gate exists to catch.

Split the work into **sequential chunks, each sized to fit comfortably inside one Claude Code
session — target no more than ~200k tokens of context to complete it.** Estimate from concrete
things, not vibes: how many files the chunk opens, how large they are, how much output it
writes, how many test runs it takes to converge. A chunk that has to hold the whole schema plus
six call sites in mind is too big; split it.

**Each chunk is executed by its own agent, in a fresh session, with no memory of the others.**
That is what the sizing is for — the boundaries are real context resets, not headings. Two
consequences you have to plan around:

- **A chunk must stand alone.** Its agent gets your chunk text, a summary of the whole change,
  and the handoff documents the chunks before it wrote — nothing else of yours. Name exact file paths,
  function names, and the existing patterns to follow. "Update the callers" is useless to someone
  who wasn't there when you found them; list them.
- **A chunk must end green** — test/typecheck/lint all passing, so the worktree is safe to hand
  to a stranger. Never split so that chunk 1 leaves the build broken until chunk 2 lands. If the
  work genuinely cannot be split that way, say so and explain why rather than inventing a false
  seam; one honest large chunk beats two that only work if the same agent does both.

Fewer, well-sized chunks beat many small ones: every boundary costs a fresh agent re-reading the
codebase. Split where the context actually gets heavy, not to make the plan look tidy.

**A chunk that touches user-visible code also has to produce screenshots**, which is real work:
a temporary harness route rendering the changed component, fixture data seeded into the app's
query cache, a dev server, a throwaway Playwright script, then tearing all of it down. Budget for
it in that chunk's estimate, and note which existing dev-route and fixture patterns the agent
should mirror — you have read the code and they have not.

Return a plan with:

1. **Summary** — what changes, in two or three sentences. This is handed to every chunk agent as
   their only picture of the whole.
2. **Chunks**, numbered, in order. For each: a title, the files it touches, what it does, how it
   is verified, what the chunks before it will have left in place that it depends on, and your
   context estimate with the reasoning behind it.
3. **Risks and ambiguities** — anything you had to assume, anything that could break outside the
   files you listed, any existing behaviour the change would alter.
4. **Out of scope** — what you deliberately are not doing, so the reviewer does not flag it.

Be concrete about file paths and function names throughout. None of the agents that execute this
have any of your context.

## The explainer — for the human, not the agents

The plan above is what the implementer agents are handed. The human approving it gets something
else as well: **`{{STATE_DIR}}/plan-explainer.html`**, written by you, which they open in a
browser and read before saying yes. Write it **after** the plan is settled, from the same
understanding, so the two never disagree — and name its absolute path in your final message.

Why it exists: the approval gate only works if the approver actually understands what they are
approving, and a chunked plan with token estimates is written for agents, not for them. The
explainer is the same plan re-told for someone who will skim it — so it leads with the places
where a skim most needs to stop.

**Who you are writing for.** A strong engineer who does **not know this codebase**. Explain this
repo's modules, names, layout and conventions — where the touched code lives, what each file is
for, how a request or piece of data moves through the part you are changing. Do not explain
general concepts (what a migration is, what an ORM does, how React Query caches); they know.
Show them **real code** — short, exact excerpts from the worktree with paths and line numbers —
rather than describing it, because they can read code faster than prose about code, and because
an excerpt lets them check your reading of it.

**Start from the skeleton: copy `{{SKILL_DIR}}/explainer-skeleton.html` to
`{{STATE_DIR}}/plan-explainer.html` and fill every `FILL` comment.** It fixes the section order
and the styling so every run reads the same; your job is the content. Keep it self-contained —
no external scripts, styles, fonts or images, nothing that references a sibling file — because
it is **published to a public, unlisted, permanent URL** so the human can read it from another
device while this runs on a remote box. That has one hard consequence: **no secrets in the
excerpts.** Env values, keys, tokens, connection strings, customer or personal data — if an
excerpt contains one, cut that line and say `[redacted]`. Code structure is fine; credentials
never are.

The order is deliberate and you must keep it:

1. **Decisions made on their behalf.** Every ambiguity you resolved, every place the issue was
   silent and you picked a side — as a question, with what you chose, the realistic alternative,
   the evidence that tipped it, and what gets built wrongly if you were wrong. Biggest blast
   radius first. This is the section that earns the page its place: a plan approved without
   reading is a plan whose silent decisions were never checked. If there were genuinely none,
   say so in the TL;DR rather than inventing some.
2. **The ask, restated** in your own words — so a misreading of the issue is visible at the top,
   not discovered in review.
3. **How this area works today** — the orientation, with a flow of the touched path, a file
   table, and real excerpts of the patterns the implementers were told to mirror.
4. **What changes**, chunk by chunk — before/after sketches or pseudo-diffs, and for each chunk
   the **observable difference**: what a user, caller or test sees afterwards that it did not before.
5. **What could break** — behaviour that changes, contracts other code depends on, callers outside
   the listed files, data implications, and honestly what the automated checks will *not* catch.
6. **How we'll know it works**, **Deliberately not doing**, and **The plan** as a compact table.

Every section opens with a one-line TL;DR, so a reader who stops after the first line of each
still leaves with the gist. Keep each section short enough to actually be read: this is a
briefing, not documentation. Prefer one real excerpt to three paragraphs about it.
