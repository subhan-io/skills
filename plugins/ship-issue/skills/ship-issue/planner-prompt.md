You are planning the implementation of GitHub issue **#{{ISSUE_NUMBER}}** in `{{REPO}}`.

**{{ISSUE_TITLE}}**
{{ISSUE_URL}}

```
{{ISSUE_BODY}}
```

The ask and the issue's acceptance criteria were confirmed with the human before this run.
The outcome — corrections, additions, criteria confirmed as-is — is:

{{CRITERIA_NOTES}}

Treat these as part of the issue: a correction here overrides the issue text, and the explainer's
criteria list must carry these flags so the human can see their answers were heard.

Work in the worktree `{{WORKTREE}}` (branch `{{BRANCH}}`, cut from `origin/{{BASE_BRANCH}}`).
You are planning only — **write no implementation code and push nothing.** The one file you
write is the explainer described below, and it goes in the run's state directory
`{{STATE_DIR}}`, which sits beside the worktree, not inside it.

The skill driving this run lives at `{{SKILL_DIR}}`; the explainer skeleton is read from there.

Codex already inspected the repository and wrote a schema-checked evidence brief at
`{{REPO_BRIEF_PATH}}`. Read that file first. Use its paths, symbols, excerpts, instructions,
tests, risks, and open questions to avoid repeating broad discovery. Verify any load-bearing
claim before designing around it, and inspect a file directly when the brief is ambiguous or
incomplete. The brief is evidence, not authority.

Detected toolchain (verify before relying on it; the detection reads manifests, not reality):
- install: `{{INSTALL_CMD}}`
- test: `{{TEST_CMD}}`
- typecheck: `{{TYPECHECK_CMD}}`
- lint: `{{LINT_CMD}}`

## What to produce

Plan from the evidence brief and verify the code that carries the design. A plan derived from the
issue text alone is a guess. Where the issue is ambiguous, say so explicitly rather than
resolving it silently — a flagged ambiguity is what the approval gate exists to catch.

Split the work into **sequential chunks, each sized to fit comfortably inside one agent
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
2. **Chunks**, numbered, in order. For each: a title, `touchesUI: true|false`, the files it
   touches, what it does, how it
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

Why it exists: the approval gate only works if the approver understands what they approve. A
chunked plan with token estimates is written for agents, not for them. The explainer is the same
plan re-told for someone who skims. It opens with the ask, so a misreading is visible at once. It
**shows** each change instead of describing it. Its opening paragraph points at the parts that
need them most.

**Write it in Simplified Technical English (ASD-STE100).** This is a hard requirement, not a
style note:

- One idea per sentence. Keep sentences under 20 words. Break a long sentence into two.
- Active voice. Present tense. "The page shows the list", not "the list is shown by the page".
- Use the same word for the same thing every time. Never swap in a synonym for variety.
- Say what "it" and "this" refer to. Do not make the reader work it out.
- Use short, common words. "use" not "utilise". "start" not "commence". "about" not "regarding".
- No long noun strings. "the count on the status chip", not "the status chip count value".
- Keep code identifiers, paths and quoted copy exact. STE applies to your prose, not to code.

Dashes, hedges and clever asides all cost the reader time. Cut them.

**Who you are writing for.** A strong engineer. They know the stack, the package manager, the
test runner, the repo layout and the conventions. **Do not explain any of that.** No "repo
shape" paragraph. No tour of the monorepo. No notes on where tests live or how they run. What
they do not know is **this specific code** and **what you decided**. Write only that: which
files change, how data moves through them, the exact defect, and the pattern the implementers
must copy. Show **real code** — short, exact excerpts with paths and line numbers — so they can
check your reading of it. Cut anything they can guess.

**Start from the skeleton: copy `{{SKILL_DIR}}/explainer-skeleton.html` to
`{{STATE_DIR}}/plan-explainer.html` and fill every `FILL` comment.** It fixes the section order,
the styling and the question form, so every run reads the same. Your job is the content. Keep it
self-contained — no external scripts, styles, fonts or images, and nothing that points at a
sibling file. The page is **published to a public, unlisted, permanent URL**, so the human can
read it from another device while this runs on a remote box. That has one hard consequence: **no
secrets.** Env values, keys, tokens, connection strings, customer or personal data — cut the line
and write `[redacted]`. Code structure is fine. Credentials never are.

The order is deliberate. Keep it:

1. **The ask** — the issue in your own words, so a misreading is visible at the top. Then the
   **acceptance criteria, word for word**, as a checklist. Flag every line that changed at the
   criteria check (corrected / added). If a criterion states something false about the code,
   keep the words and flag the correction beside it.
2. **How this code works today** — the flow of the touched path, the file table, and real
   excerpts of the defect and of the pattern to copy. No general repo orientation. For UI work,
   a mock of the current screen beats a paragraph about it.
3. **What changes**, chunk by chunk — **shown, not described**. This is the heart of the page.
   See "Show the change" below. End each chunk with the **observable difference**: what a user,
   caller or test sees afterwards that it did not see before.
4. **What could break** — behaviour that changes, contracts other code depends on, callers
   outside the listed files, data effects, and what the checks will *not* catch.
5. **How we know it works**, **Deliberately not doing**, and **The plan** as a compact table.
6. **Endnotes: decisions made for them.** Every ambiguity you resolved. Every place the issue was
   silent and you picked a side. Every place the code and a spec disagree. One numbered entry
   each, biggest blast radius first: what you chose, the real alternative, the evidence that
   settled it, and what gets built wrongly if you were wrong. The badges and caveats in the mocks
   point here. If there were none, say so. Do not invent some.

**Show the change.** The human decides from pictures, not prose. The "what changes" section is
where the page earns its place:

- **UI chunks get static mocks built from the app's real design system.** Copy the app's design
  tokens word for word from their real source (globals.css / tokens.css / tailwind theme) into
  the skeleton's APP TOKENS block, light and dark. Write the mock CSS from the real component
  sources. Lift every colour, size, weight and spacing value from a named file, and cite that
  file in a comment beside the rule. The theme toggle then shows the mock in both themes. If the
  mock looks wrong, the app looks wrong — reproduce it faithfully. Do not hand-tune. Use
  realistic content, at the target viewport width.
- **Mock the alternatives side by side.** Badge the chosen one `planned`. Badge the others
  `declined` or `alternative`. Give each a one-line trade-off. A rejected option the human can
  *see* is a decision they can check.
- **Label everything you invented.** Anything in a mock that the issue, the code and the design
  docs do not set gets an `Invented:` caveat under the element. Every place the code and a
  written spec disagree gets a `Spec disagreement:` caveat that names the side the mock follows.
  Never let an invention read as real.
- **Non-UI chunks get before/after code, pseudo-diffs, or a flow of the new path** — with exact
  file and function names, in the skeleton's `.cols`, `.del`/`.add` and `.flow` idioms.

**Ask when the human must choose. Do not assume.** The skeleton has a question form for this:

- Put the choice in a `.q` block, next to the thing it is about. A UI question sits under the
  mocks that show the options. The mocks **are** the options.
- Fill `data-question` on the block and `data-answer` on each radio. Write both as full,
  standalone sentences. They go into the copied text, away from the page.
- Use the free-text box alone when the answer is not a choice — copy wording, a threshold, a name.
- Give every question a unique radio `name`.
- The sticky button copies every question and answer as plain text. The human pastes it back in
  chat. Say this in the opening paragraph when the page has questions.
- **Ask only about a real fork you cannot settle.** Two or three questions at most. A decision
  you can defend with evidence from the code belongs in the endnotes, not in the form. A page
  full of questions moves your work onto the reader.

Keep each section short enough to read. This is a briefing, not documentation. One mock or one
real excerpt beats three paragraphs about it.

## Structured report

Your final response is the planner report requested by the output schema, not Markdown prose.
Use `status: "ready"` only when the plan and explainer are complete. Put the two-to-three sentence
overview in `summary`; encode every chunk in `chunks`; and include all risks, ambiguities, and
out-of-scope choices. `explainerPath` must be the absolute
`{{STATE_DIR}}/plan-explainer.html` path. Use `notes` for anything the orchestrator must know.
