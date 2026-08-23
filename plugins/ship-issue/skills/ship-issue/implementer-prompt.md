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

Those are handoff documents, one per chunk that ran before you, oldest first — each written by
that chunk's agent for whoever came next, which is you. **Read all of them before you touch
code.** They are the only continuity you get, and the last one was written for your chunk
specifically.

They describe what those agents actually did, which can differ from what the plan said they would.
**Where a handoff and the plan disagree, the handoff wins**: it describes the repo you are about
to open. Verify anything load-bearing by reading the code rather than trusting either.

If one of the paths is missing or unreadable, **stop and report that** rather than working around
the gap — you would be building on a chunk whose actual shape nobody can tell you.

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
- the gate the issue itself names: `{{ISSUE_STATED_COMMANDS}}`

A command listed as `null` was not detected — find the real one (read `package.json` scripts,
the CI workflow, the Makefile) rather than skipping the gate silently. Where the issue names its
own gate and it differs from the detected ones, **the issue wins** — in a workspace the real
check is often app-local (`cd apps/foo && pnpm check`) while detection reports the root scripts.
Run both rather than assuming one implies the other.

The skill driving this run lives at `{{SKILL_DIR}}` — that is where the files referenced below
are, and it is not the repo you are changing. Nothing you write ever goes there.

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

The procedure — but first, **check you can publish before you capture**: resolve `upload.sh` (step
5) and confirm `infisical` and `aws` are on `PATH`. Ten seconds up front beats building a harness,
taking the shots, and only then finding there is nowhere to send them. If publishing is
unavailable, say so in your report and skip the capture rather than producing images no one will
see.

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
   repo's test suites use. Background it, record its PID (`$!`), and wait for its ready line
   before navigating.
   - **Stop it later with that PID, never `pkill -f <port>`.** Your own shell command line
     contains the port, so the pattern matches the shell running it and kills your session
     mid-chunk. `kill "$devpid"` is the whole fix.
4. **Capture with an uncommitted throwaway script** — import `chromium` from the app's own
   Playwright dev dependency and drive it headless. Shoot desktop (1440×900) and, when the change
   is layout-sensitive, mobile (402×874 — iPhone 17 Pro; use that explicit viewport rather than
   Playwright's `devices["iPhone 17 Pro"]` entry, whose height subtracts Safari's chrome). This is
   *not* the same as running the repo's e2e or functional suites: those often need a shared
   database and fixed ports and may be off-limits to agents; your own script on your own port with
   your own fixtures is safe regardless.
   - If a shot comes back blank or mid-skeleton, **wait on a real selector**, never a sleep.
   - Never retry a failed browser launch in a loop. If Chromium is missing, install it once, then
     report the failure if it still won't start.
   - A dev server often paints a framework badge over the page (Next.js draws a floating dev
     indicator). Turn it off in config for the run, or the evidence ships with a widget on it.
   - A throwaway script living outside the repo cannot `import` the app's Playwright — Node
     resolves from the script's own path, and `/tmp` has no `node_modules`. Anchor a
     `createRequire` at the app's `package.json` and `require("@playwright/test")` from there.
5. **Publish each shot, before you delete anything.** The URL is the only part of the capture
   that survives; a deleted PNG cannot be uploaded and the shot has to be retaken from scratch.
   Use the `pr-media-upload` skill, which uploads to a public bucket and echoes one line — the
   URL — to stdout. **The orchestrator passes you its absolute path** — use that verbatim if you
   have it. Otherwise search rather than guessing at the nesting depth, because the plugin-cache
   layout buries it several levels down:

   ```sh
   upload=$(find "$HOME/.codex/plugins" "$HOME/.claude/plugins" "$HOME/.claude/skills" \
              -path '*pr-media-upload/upload.sh' -type f -perm -u+x 2>/dev/null | head -1)
   url=$("$upload" ./shot-desktop.png)
   ```

   Record every URL before moving on. They go in your report, and the orchestrator embeds them in
   the PR body — images as `![alt](url)`, video (`.mp4/.mov/.webm`) as a raw
   `<video src="url" controls width="640">` tag on its own line.
6. **Then tear all of it down.** Kill the dev server; delete the script, the images, and the
   harness route. **None of it may appear in the PR diff** — it exists only to render your
   component in a real browser. Your actual tests are the coverage; the screenshot is evidence
   for the human.

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

## Hand off to the next chunk

The agent that runs the chunk after yours starts from zero: fresh session, none of your context,
only what you write down. So finish by writing it a handoff document.

**Read `{{SKILL_DIR}}/handoff-prompt.md` and follow it.** It says where the document goes, what it
must contain, and how to write for a reader who was not here. It also says to invoke the `handoff`
skill (`Skill` tool, name `handoff`) when that skill is installed and let it do the writing —
prefer that, then check the result against the required sections. When it is not installed, the
bundled instructions are the whole method; the document comes out the same either way.

It goes in this run's state directory — **`{{STATE_DIR}}/chunk-{{CHUNK_NUMBER}}-handoff.md`**.
That directory sits beside the worktree, not inside it, so nothing you write there can reach the
PR diff. The approved plan is in the same place, at `{{STATE_DIR}}/plan.md`.

Either way, frame the document around what the next session does — `implementing the next chunk of
issue #{{ISSUE_NUMBER}} in worktree {{WORKTREE}}` — which is also the argument to pass the skill
if you invoke it. If you were the last chunk ({{CHUNK_NUMBER}} of {{CHUNK_TOTAL}}), the next
session opens the PR instead; say so, and write for that reader.

## Report back

Short — the detail lives in the handoff document, and the orchestrator reads that. It needs:

- **Status** — green and pushed, or stopped early.
- **Handoff document** — its absolute path.
- **Done** — two or three lines on what landed.
- **Anything that changes the rest of the plan** — a chunk that can no longer work as written, a
  dependency the plan missed. Say it here too; this is what decides whether the run continues.
- **Screenshots** — the published URLs, or the `un-capturable:` reason.
- **Verification** — the commands and their actual results.
