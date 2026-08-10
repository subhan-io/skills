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

Each chunk must be **independently verifiable** — it ends with the repo in a state where the
test/typecheck/lint commands pass. Never split so that chunk 1 leaves the build broken until
chunk 2 lands. If the work genuinely cannot be split that way, say so and explain why rather
than inventing a false seam.

Return a plan with:

1. **Summary** — what changes, in two or three sentences.
2. **Chunks**, in order. For each: a title, the files it touches, what it does, how it is
   verified, and your context estimate with the reasoning behind it.
3. **Risks and ambiguities** — anything you had to assume, anything that could break outside the
   files you listed, any existing behaviour the change would alter.
4. **Out of scope** — what you deliberately are not doing, so the reviewer does not flag it.

Be concrete about file paths and function names. The next agent has none of your context.
