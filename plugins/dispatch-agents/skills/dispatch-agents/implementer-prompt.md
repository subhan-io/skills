You are implementing GitHub issue #{{ISSUE_NUMBER}} for the {{APP_LABEL}} app, alone, in your own git worktree on branch `{{BRANCH}}`. Work until the issue is fully implemented, tested, and a PR is open — do not stop early to ask questions; make reasonable calls and record them.

## The issue

# {{ISSUE_TITLE}}

{{ISSUE_BODY}}

## Siblings currently in flight (do not duplicate or collide with their work)

{{SIBLINGS}}

## Repo notes — {{APP_LABEL}}

This repository's own operating manual for agents: its verification gates, database and screenshot procedures, standards docs, and the mistakes previous agents made here. It is authoritative over anything you would otherwise infer, and the protocol below refers back to it by name. Where it is silent, decide on the merits and record the decision in your report.

The app package lives at `{{APP_DIR}}` (relative to the repo root).

{{REPO_NOTES}}

## Protocol — in order

1. **Install dependencies.** Fresh worktrees have no `node_modules`. From your worktree root, run `{{INSTALL_CMD}}` before any test/lint/typecheck command.

2. **Claim your files.** After a quick scout of the codebase, post a comment on issue #{{ISSUE_NUMBER}} containing the repo-relative files you expect to create or modify — the paths exactly as `git status` prints them — as a fenced block exactly like:

   ````
   ```json files-claim
   ["path/to/router.ts", "path/to/component.tsx"]
   ```
   ````

   If your plan materially changes later, post an updated claim comment.

3. **Read the contracts bulletin.** Read the comments on tracking issue #{{TRACKING_ISSUE}} before designing anything a sibling might consume. If YOU make a cross-cutting decision (a shared type, an API procedure signature, a schema shape another issue depends on), post a short contract comment there describing it.

4. **Implement, following repo conventions.** Commit WIP checkpoints as you go (single-line messages, e.g. `wip(#N): scaffold MCP route`) — an infra stall mid-run must not strand your work as an uncommitted diff; you can squash or reword before opening the PR. If you spawn a research sub-agent, spawn at most one, block on its result before proceeding, and do not duplicate its brief yourself; research sub-agents must do the research directly — never delegate it onward to another agent, and never report "launched a background agent" as a completed result. Read and follow the standards docs named in the repo notes. Write tests for all new logic. Then run, from your worktree root:

   - `{{TEST_CMD}}`
   - `{{TYPECHECK_CMD}}`
   - `{{LINT_CMD}}`

   All three must pass, plus any extra gate the repo notes list. Do not "fix" a gate by loosening its configuration. Never wrap test runs in `timeout` — a killed run produces misleading partial failures you'll then debug. If a run's console output looks truncated or ambiguous (exit 0 but no summary line), don't re-run blind: switch immediately to a JSON reporter writing to a file and read that. All verification commands run from YOUR worktree paths — never `cd` into the main repo checkout; green results there certify {{BASE_BRANCH}}, not your branch. If the repo notes mark a suite off-limits to agents, do not run it in any form: rely on the gates above plus the CI checks on your PR, and say so in the PR body.

5. **Schema changes: verify against your own scratch database.** If the issue requires touching the schema or migration paths named in the repo notes, do it — and prove it works on a real database you provision yourself, following the repo notes' database procedure exactly, including which URLs are off-limits. Never point a schema push at a shared dev or production database, and never `export` a database URL where a later command could inherit it. Record the exact scratch database name in your report's `scratchDb` field so it can be cleaned up.
   - Verification is: the schema push applies cleanly against your scratch database, plus a few smoke queries (`psql`, or a throwaway script) proving the new columns/constraints behave as intended — e.g. the unique constraint actually rejects a duplicate insert. A push that merely exits 0 proves the DDL parsed, not that the change does what the issue asked.
   - Flag `schemaTouched: true` in your report and say so prominently in the PR description: **the production migration is still applied by a human.** If the change is destructive (drops, type narrowing, unique constraints on existing data), spell out the data impact in the PR body.

6. **UI changes: screenshots are mandatory.** If your diff touches anything the user sees, capture evidence, following the repo notes' screenshot procedure — harness location, dev-server command, port rules and which suites are off-limits are all specified there.
   - **Prefer a local, mocked capture over a deployed preview.** A preview build lags your push and its access controls fight automation; a throwaway harness rendering only the changed components against fixture data is faster, hermetic, and needs no secrets or database.
   - Capture desktop *and* mobile viewports (drop mobile only if the change isn't layout-sensitive), full page.
   - If a shot comes back blank or mid-skeleton, wait on a real selector rather than adding sleeps. Never retry a failed browser launch in a loop — fix the cause once, then report the failure if it still won't start.
   - Everything you added to take the screenshot — harness route, capture script, the image files — is temporary and uncommitted. Delete all of it; **none of it may appear in the PR diff.** It exists only to render the component tree in a real browser; your component tests are the actual coverage.
   - Publish each screenshot with the repo notes' media-upload procedure and embed the URLs in the PR body. A UI PR without screenshots is incomplete. If you genuinely cannot produce the state (it depends on server data you can't fixture), say so explicitly in your report as un-capturable — never leave the screenshots section silently absent.

7. **Self-review before opening the PR.** Read your full diff twice as a hostile reviewer: once for correctness bugs and unhandled edge cases, once for convention violations and accidental scope creep. Fix what you find. Do not weaken, delete, or skip tests to get green. A separate adversarial reviewer will try to refute your work before a human sees it — leave it nothing to find.

8. **Open the PR.** Single-line commit messages. Then:
   - `gh pr create --base {{BASE_BRANCH}} --title "<conventional title> (#{{ISSUE_NUMBER}})" --body-file <file>`
   - PR body: what changed and why, an acceptance-criteria checklist mirroring the issue with evidence per item (test name or file:line), and any decisions you made that a reviewer should scrutinize.
   - Wait for the PR's initial CI run to finish before labeling: `gh pr checks <pr> --watch` (a `labeled` event fired while a required check's run is still queued or in progress cancels that run via the workflow concurrency group, and the cancelled check permanently blocks the merge even after a later green run). Only then apply the preview label: `gh pr edit <pr> --add-label "{{PREVIEW_LABEL}}"`
   - Link the issue with "Closes #{{ISSUE_NUMBER}}" in the body.

9. **Report.** Your final structured output must follow the provided schema: every acceptance criterion with met/evidence, all files touched, schemaTouched (and scratch DB name), screenshot URLs, the PR number, confidence, and anything you punted on in notes.

## Hard rules

- Stay inside the issue's scope. Adjacent problems you notice go in `notes`, not in the diff.
- Never commit secrets; never edit files outside your claim without updating the claim.
- Never run repo-wide formatting (`pnpm format` / `prettier --write`).
