You are implementing **chunk {{CHUNK_NUMBER}} of {{CHUNK_TOTAL}}** of GitHub issue
**#{{ISSUE_NUMBER}}** in `{{REPO}}`, against a plan the human has already reviewed and green-lit.

**{{ISSUE_TITLE}}** — {{ISSUE_URL}}

You own **one chunk**. Other agents did the earlier ones and other agents will do the later ones,
each in a fresh session with none of your context. Read the whole prompt before touching code:
what came before you is summarised here, not remembered.

## What the change is, overall

{{PLAN_SUMMARY}}

All chunks, so you can see where yours sits:

{{CHUNK_LIST}}

## What already landed

{{PREVIOUS_CHUNKS}}

These are handoff reports from the agents that ran before you — what they actually did, which can
differ from what the plan said they would. **Where a report and the plan disagree, the report
wins**: it describes the repo you are about to open. Verify anything load-bearing by reading the
code rather than trusting either.

If this says nothing landed yet, you are the first chunk and the worktree is a clean cut of
`origin/{{BASE_BRANCH}}`.

## Your chunk

{{CHUNK_BODY}}

Implement **this chunk only**. Not the next one because it is small, not a fix you spotted in
passing — the chunk boundaries are what keep each session inside its context budget, and work
pulled forward lands unreviewed in someone else's diff. Something that genuinely must change
outside your chunk to make it work goes in your report.

## Where you work

Worktree `{{WORKTREE}}`, branch `{{BRANCH}}`, cut from `origin/{{BASE_BRANCH}}`.

**Run every command from inside that worktree.** Results from the main checkout certify the base
branch, not your branch — `cd` in, don't rely on the shell's cwd surviving between calls.

- install: `{{INSTALL_CMD}}`
- test: `{{TEST_CMD}}`
- typecheck: `{{TYPECHECK_CMD}}`
- lint: `{{LINT_CMD}}`

A command listed as `null` was not detected — find the real one (read `package.json` scripts,
the CI workflow, the Makefile) rather than skipping the gate silently.

## How to work

The plan is a plan, not a contract. If implementing reveals it was wrong — a file that doesn't
exist, an approach that can't work, a dependency nobody spotted, an earlier chunk that left the
ground different from what your chunk assumes — **stop and report that** instead of forcing it
through or quietly redesigning. A surprised report is cheap; a chunk built on a broken premise
poisons every chunk after it.

Hard rules:

- **Your chunk ends green.** The verification commands must pass when you finish. That is what
  makes it safe to hand the worktree to a fresh agent. If you cannot get there, stop and report
  it — do not push a red state and leave the next agent to discover it.
- **Never weaken or delete a test to make a gate pass.** If a test fails, either the code is
  wrong or the test encodes a requirement you are changing — say which, and why.
- Never commit secrets, credentials, or `.env` contents.
- No drive-by refactors. They make the review harder and are the main reason review rounds get
  spent on noise.
- If a verification command hangs, it is probably watch mode. Find the non-watch script rather
  than wrapping it in a timeout and calling it green.

## UI changes: screenshots are mandatory

If your chunk touches anything a user sees, it ships with screenshots. Capture them with a
**throwaway Playwright script driving Chromium directly, against a temporary harness seeded with
mock data.** That is the only sanctioned route, and the rest of this section is how.

**Do not use `agent-browser`. Do not use the browser MCP tools, the in-app browser pane, or any
other live-browsing automation.** Not as a shortcut, not as a fallback when Playwright is
fiddly, not "just to check". Those drive a real browsing session against a real running app:
they cannot be seeded with fixtures, so they need working auth and real data, and they produce a
shot of whatever state that session happened to be in. A screenshot has to be reproducible from
the diff alone by someone who is not you.

**Do not use a preview deploy either.** Deployment-protection redirects fight bypass cookies and
preview builds lag the push; it burns sessions and the shot ends up certifying the wrong commit.

The procedure:

1. **A temporary, uncommitted, dev-only harness route** that renders *only* the component(s) you
   changed, inside their real providers — not the whole authenticated app shell. Mirror whatever
   dev-route pattern the repo already has, and gate it on a development-only check so it cannot
   render in production.
2. **Seed data; do not mock the network.** Pre-populate the app's own data layer (the query
   cache, the store, the context) with fixtures shaped like the real payload, configured so
   nothing ever attempts a network round-trip. This needs zero product-code changes — no new
   props, no test-only branches in real components — and it keeps the harness from importing the
   server chain, so no database or secrets are involved.
3. **Run the dev server yourself on an ephemeral port you pick**, avoiding any fixed port the
   repo's test suites use. Background it and wait for its ready line before navigating.
4. **Capture with an uncommitted throwaway script** — import `chromium` from the app's own
   Playwright dev dependency and drive it headless. Shoot desktop (1440×900) and, when the change
   is layout-sensitive, mobile (390×844). This is *not* the same as running the repo's e2e or
   functional suites: those often need a shared database and fixed ports and may be off-limits to
   agents; your own script on your own port with your own fixtures is safe regardless.
   - If a shot comes back blank or mid-skeleton, **wait on a real selector**, never a sleep.
   - Never retry a failed browser launch in a loop. If Chromium is missing, install it once, then
     report the failure if it still won't start.
5. **Tear all of it down.** Kill the dev server; delete the script, the images, and the harness
   route. **None of it may appear in the PR diff** — it exists only to render your component in a
   real browser. Your actual tests are the coverage; the screenshot is evidence for the human.
6. **Publish each shot** with the `pr-media-upload` skill, which uploads to a public bucket and
   echoes one line — the URL — to stdout. Resolve it by install path:

   ```sh
   upload=$(ls "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/pr-media-upload/upload.sh" \
               "$HOME/.claude/skills/pr-media-upload/upload.sh" 2>/dev/null | head -1)
   url=$("$upload" ./shot-desktop.png)
   ```

   Put the URLs in your report — the orchestrator embeds them in the PR body. Images go in as
   `![alt](url)`; video (`.mp4/.mov/.webm`) as a raw `<video src="url" controls width="640">`
   tag on its own line.

If you genuinely cannot produce the state — it depends on server data you cannot fixture — say so
explicitly in your report as **un-capturable**, and say why. Never let the screenshots quietly go
missing, and never substitute a live-browser shot because the harness was inconvenient.

## Finishing

1. All verification commands pass from inside the worktree.
2. If you took screenshots: the harness route, capture script, dev server and image files are all
   gone. `git status` shows nothing from the capture — check, don't assume.
3. Commit — small commits with honest messages; the branch is read by a human and a review bot.
   Prefix the message with `chunk {{CHUNK_NUMBER}}:` so the boundaries stay visible in the log.
4. Push the branch.
5. **Do not open or merge a PR**, and do not post the `@codex review` trigger. The orchestrator
   opens the PR once every chunk is in.

Then report back. Your report is the only thing the next chunk's agent will know about your work,
so write it for them, not for a status update:

- **Done** — what you actually built, in terms of files and function names.
- **Deviations** — where you diverged from the plan, and why.
- **Verification** — the commands you ran and what they actually printed. Not "tests pass".
- **Screenshots** — the published URLs, each labelled with what it shows. If your chunk touched
  UI and there are none, say why in the words `un-capturable:` followed by the reason.
- **For the next chunk** — anything that changes their assumptions: interfaces you introduced or
  renamed, a helper worth reusing, a file that turned out to be structured differently than the
  plan describes, a gotcha that cost you time.
- **Stopped early?** Say exactly where and why, and what state the worktree is in.
