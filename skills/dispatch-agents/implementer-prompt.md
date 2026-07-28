You are implementing GitHub issue #{{ISSUE_NUMBER}} for the {{APP_LABEL}} app, alone, in your own git worktree on branch `{{BRANCH}}`. Work until the issue is fully implemented, tested, and a PR is open — do not stop early to ask questions; make reasonable calls and record them.

## The issue

# {{ISSUE_TITLE}}

{{ISSUE_BODY}}

## Siblings currently in flight (do not duplicate or collide with their work)

{{SIBLINGS}}

## Protocol — in order

1. **Install dependencies.** Fresh worktrees have no `node_modules`. From the repo root, run `pnpm install --frozen-lockfile` before any test/lint/typecheck command.

2. **Claim your files.** After a quick scout of the codebase, post a comment on issue #{{ISSUE_NUMBER}} containing the repo-relative files you expect to create or modify, as a fenced block exactly like:

   ````
   ```json files-claim
   ["apps/resume-evaluator/server/api/routers/foo.ts", "..."]
   ```
   ````

   If your plan materially changes later, post an updated claim comment.

3. **Read the contracts bulletin.** Read the comments on tracking issue #{{TRACKING_ISSUE}} before designing anything a sibling might consume. If YOU make a cross-cutting decision (a shared type, a tRPC procedure signature, a schema shape another issue depends on), post a short contract comment there describing it.

4. **Implement, following repo conventions.** Commit WIP checkpoints as you go (single-line messages, e.g. `wip(#N): scaffold MCP route`) — an infra stall mid-run must not strand your work as an uncommitted diff; you can squash or reword before opening the PR. If you spawn a research sub-agent, spawn at most one, block on its result before proceeding, and do not duplicate its brief yourself; research sub-agents must do the research directly — never delegate it onward to another agent, and never report "launched a background agent" as a completed result. CLAUDE.md and docs/CODING_STANDARDS.md apply. Write tests for all new logic. Run, from the app directory: `pnpm test`, and from the repo root: `pnpm typecheck --filter={{APP_LABEL}}` and `pnpm lint --filter={{APP_LABEL}} -- --max-warnings=0`. All three must pass. Note: `eslint-plugin-only-warn` demotes every lint rule to a warning, so a bare `pnpm lint` exits 0 regardless of violations — `--max-warnings=0` is the only thing that makes lint an actual gate; don't drop it. Never wrap test runs in `timeout` — a killed run produces misleading partial failures you'll then debug. If a run's console output looks truncated or ambiguous (exit 0 but no summary line), don't re-run blind: switch immediately to a JSON reporter writing to a file and read that. All verification commands run from YOUR worktree paths — never `cd` into the main repo checkout; green results there certify master, not your branch.

   **Never run the Playwright suites locally** (`pnpm test:e2e`, `pnpm test:functional`, or `playwright test` in any form). They bind fixed ports (3001/4141/8080) and seed the shared dev database, so parallel agents would collide with each other and with the user's own runs. CI covers them with full isolation: the `functional` job runs on every PR automatically, and `e2e-smoke` runs when the PR carries the deploy-preview label. Your local gates are exactly the three commands above; if your change touches e2e specs, the stub-AI fixtures, or the Playwright configs, rely on `pnpm typecheck` (fixtures are `satisfies`-typed) plus the CI checks on your PR, and say so in the PR body.

5. **Schema changes: verify against your own scratch database.** If the issue requires touching `server/db/schema.ts` or `drizzle/`, do it — and prove it works on a real database you provision yourself. This step's use of `db:push` against a self-provisioned scratch database is the one exception to the repo CLAUDE.md's "never run db:push automatically" rule — that rule still applies, unmodified, to every Infisical-provided dev/prod `DATABASE_URL`.
   - Create the scratch database with pgmanager, using the `pr` env and the issue number plus 9000 to avoid colliding with real PR-preview databases (which use the actual PR number): `pgmanager db create {{APP_LABEL}} pr $(({{ISSUE_NUMBER}} + 9000))` — pgmanager project names are `^[a-z][a-z0-9_]*$`, so use `{{APP_LABEL}}` with hyphens swapped for underscores (e.g. `resume-evaluator` → `resume_evaluator`). For issue 231 this creates `resume_evaluator_pr_9231`. Record the exact DB name in your report's `scratchDb` field so it can be cleaned up (`pgmanager db delete <project> pr $(({{ISSUE_NUMBER}} + 9000))`).
   - Point `DATABASE_URL` at the scratch DB **for that command only**, with validation skipped (env.mjs hard-requires secrets like `BETTER_AUTH_SECRET`/`AWS_*`/`GEMINI_API_KEY` that a scratch DB check has no reason to need): `SKIP_ENV_VALIDATION=1 DATABASE_URL=... pnpm --filter {{APP_LABEL}} db:push`. NEVER export `DATABASE_URL`, and NEVER run `db:push` against any Infisical-provided dev or prod URL.
   - There is no integration-test harness for this app (`vitest.config.ts` only wires jsdom; the one server test mocks the DB, nothing reads `DATABASE_URL`). Verification is: `db:push` applies cleanly against the scratch DB, plus a few smoke queries (`psql`, or a throwaway script) proving the new columns/constraints behave as intended — e.g. the unique constraint actually rejects a duplicate insert. If you want real DB-connected tests, follow the repo's `setup-app-test-harness` skill rather than inventing ad-hoc wiring; this is not mandatory for closing the issue.
   - Flag `schemaTouched: true` in your report and say so prominently in the PR description: **the production migration is still applied by a human.** If the change is destructive (drops, type narrowing, unique constraints on existing data), spell out the data impact in the PR body.

6. **UI changes: screenshots are mandatory.** If your diff touches anything the user sees (`app/`, `components/`), capture evidence:
   - **Default source: a local, mocked Playwright capture — no preview deploy, no Vercel access, no DB/auth needed.** The preview-deploy + Vercel-SSO-bypass route is unreliable in practice (deployment-protection redirects fight the bypass cookie, preview builds lag the push) and was retired as the default after #296 burned a session on it. Instead:
     1. Add a **temporary, uncommitted dev-only harness route** under `app/dev/<feature>-preview/` — `page.tsx` gates on `if (process.env.NODE_ENV !== "development") notFound()` (mirror the existing `app/dev/eval/page.tsx` pattern), and a `"use client"` sibling that renders *only* the changed component(s) inside their real providers (`QueryClientProvider` + `api.Provider` from `@/trpc/react`), not the whole authenticated app shell.
     2. **Seed data, don't mock the network.** In a `useEffect`, call `utils.<router>.<procedure>.setData(input, fixtureData)` (via `api.useUtils()`) to pre-populate the React Query cache with fixture data shaped like the real tRPC output — construct a page-local `QueryClient` with `defaultOptions.queries: { staleTime: Infinity, retry: false, refetchOnMount: false, refetchOnWindowFocus: false }` so nothing ever attempts a real network round-trip. This needs zero product-code changes (no new props, no test-only branches in real components) and zero network mocking, and it means the harness page never imports anything from `server/*` — Next.js only compiles what a route touches, so `/api/trpc` (and its `DATABASE_URL` dependency chain) is never invoked.
     3. Run `next dev` yourself on an **ephemeral port you pick** (anything outside the e2e suites' fixed ports 3001/4141/8080), with `SKIP_ENV_VALIDATION=1` since this harness needs no secrets: `SKIP_ENV_VALIDATION=1 pnpm --filter {{APP_LABEL}} dev -- -p <port>` (background it; wait for "Ready" before navigating). This is your own isolated server in your own worktree — it cannot collide with the shared dev DB, other agents, or the user's own `dev:secrets` session, which is exactly why running Playwright locally is safe here even though the repo's Playwright *suites* (`test:e2e`, `test:functional`) remain off-limits for agents (those need the shared dev DB / a deployed preview and fixed ports).
     4. Capture with a **throwaway Playwright script** — `@playwright/test` is already a dev dependency of this app, so drive Chromium directly rather than through either Playwright *suite* (`test:e2e`/`test:functional` stay off-limits: they need the shared dev DB, fixed ports, and their own configs). Write an uncommitted `tmp-shot.mjs` in your worktree, headless, and run it with `pnpm --filter {{APP_LABEL}} exec node tmp-shot.mjs`:

        ```js
        import { chromium } from "@playwright/test"
        const url = "http://localhost:<port>/dev/<feature>-preview"
        const browser = await chromium.launch()
        for (const [name, viewport] of [
          ["desktop", { width: 1440, height: 900 }],
          ["mobile", { width: 390, height: 844 }], // drop if the change isn't layout-sensitive
        ]) {
          const page = await browser.newPage({ viewport })
          await page.goto(url, { waitUntil: "networkidle" })
          await page.screenshot({ path: `shot-${name}.png`, fullPage: true })
          await page.close()
        }
        await browser.close()
        ```

        If the shot comes back blank or mid-skeleton, wait on a real selector (`await page.waitForSelector("...")`) instead of adding sleeps. Never retry a failed launch in a loop — if Chromium is missing, `pnpm --filter {{APP_LABEL}} exec playwright install chromium` once, then report the failure if it still won't start.
     5. Tear down: kill the `next dev` process, delete `tmp-shot.mjs` and the `.png` files, and **delete the temporary harness route** — none of it may appear in the PR diff (it exists only to render the component tree in a real browser for a screenshot; the component tests are the actual coverage).
   - Fallback, if the harness approach doesn't fit (e.g. the screen's rendering genuinely depends on server data you can't fixture, like a PDF byte-for-byte export): `pnpm --filter {{APP_LABEL}} dev:secrets` against the shared dev environment, read-only — never seed/mutate/stage data there. If even that can't produce the state you need, say so explicitly in your report as un-capturable; do not leave the screenshots section silently absent.
   - Upload each screenshot with the `pr-media-upload` skill (`url=$(upload.sh file)`) and embed the URLs in the PR body. A UI PR without screenshots is incomplete.

7. **Self-review before opening the PR.** Read your full diff twice as a hostile reviewer: once for correctness bugs and unhandled edge cases, once for convention violations and accidental scope creep. Fix what you find. Do not weaken, delete, or skip tests to get green. A separate adversarial reviewer will try to refute your work before a human sees it — leave it nothing to find.

8. **Open the PR.** Single-line commit messages. Then:
   - `gh pr create --base {{BASE_BRANCH}} --title "<conventional title> (#{{ISSUE_NUMBER}})" --body-file <file>`
   - PR body: what changed and why, an acceptance-criteria checklist mirroring the issue with evidence per item (test name or file:line), and any decisions you made that a reviewer should scrutinize.
   - Apply the preview label: `gh pr edit <pr> --add-label "{{PREVIEW_LABEL}}"`
   - Link the issue with "Closes #{{ISSUE_NUMBER}}" in the body.

9. **Report.** Your final structured output must follow the provided schema: every acceptance criterion with met/evidence, all files touched, schemaTouched (and scratch DB name), screenshot URLs, the PR number, confidence, and anything you punted on in notes.

## Hard rules

- Stay inside the issue's scope. Adjacent problems you notice go in `notes`, not in the diff.
- Never commit secrets; never edit files outside your claim without updating the claim.
- Never run repo-wide formatting (`pnpm format` / `prettier --write`).
