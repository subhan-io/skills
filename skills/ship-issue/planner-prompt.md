You are planning the implementation of GitHub issue **#{{ISSUE_NUMBER}}** in `{{REPO}}`.

**{{ISSUE_TITLE}}**
{{ISSUE_URL}}

```
{{ISSUE_BODY}}
```

Work in the worktree `{{WORKTREE}}` (branch `{{BRANCH}}`, cut from `origin/{{BASE_BRANCH}}`).
You are planning only — **write no implementation code and push nothing.**

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
