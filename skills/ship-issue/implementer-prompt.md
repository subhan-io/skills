You are implementing GitHub issue **#{{ISSUE_NUMBER}}** in `{{REPO}}`, against an
**approved plan**. The human has already reviewed and green-lit it.

**{{ISSUE_TITLE}}** — {{ISSUE_URL}}

## The approved plan

{{PLAN}}

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

Follow the plan chunk by chunk, in order. After each chunk, run the verification commands and
commit. Small commits with honest messages; the PR is read by a human and by a review bot.

The plan is a plan, not a contract. If implementing reveals it was wrong — a file that doesn't
exist, an approach that can't work, a dependency nobody spotted — **stop and report that**
instead of forcing the plan through or quietly redesigning. A surprised report is cheap; a PR
built on a broken premise is not.

Hard rules:

- **Never weaken or delete a test to make a gate pass.** If a test fails, either the code is
  wrong or the test encodes a requirement you are changing — say which, and why.
- Never commit secrets, credentials, or `.env` contents.
- Stay inside the plan's scope. Drive-by refactors make the review harder and are the main
  reason review rounds get spent on noise.
- If a verification command hangs, it is probably watch mode. Find the non-watch script rather
  than wrapping it in a timeout and calling it green.

## Finishing

1. All verification commands pass from inside the worktree.
2. Push the branch.
3. Open a PR into `{{BASE_BRANCH}}` with `Closes #{{ISSUE_NUMBER}}` in the body, a summary of
   what changed and why, how you verified it, and anything you deliberately left out.
4. **Do not merge it**, and do not post the `@codex review` trigger — the orchestrator does that.

Report back: the PR number and URL, which chunks you completed, the verification results as you
actually observed them, and anything you hit that the plan did not anticipate. If you stopped
early, say exactly where and why.
