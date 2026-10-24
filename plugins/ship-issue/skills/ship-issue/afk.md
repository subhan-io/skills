# AFK mode

Read this file when the invocation says `afk`. The run is unattended: both gates
self-resolve and the run merges its own PR. Everything in `SKILL.md` applies
except what this file changes.

- **Eligibility.** Any tier, when you can state the criteria confidently from
  the issue body and comments. When you cannot, the issue is not AFK-eligible:
  stop and report why instead of guessing.
- **Gate 1**: derive the criteria from the issue and log them in the run-start
  report instead of asking. **Step 3**: an open question with no answer in the
  issue is an eligibility failure, not a guess. **Gate 2**: self-approve the plan;
  a plan that should split becomes a split proposal, reported back, never
  executed. **Step 5**: a `replan` that keeps the scope and criteria continues;
  one that changes either stops the run, and the report says what the chunk
  found.
- **Review**: step 7's rounds apply as written. A valid critical or high finding
  from round two that a fix cannot clear stops the run unmerged.
- **Merge.** When the last round's fixes are pushed, wait for CI. When the
  `t3-code` MCP server exposes `watch_pull_request`, call it on the PR and end
  the turn: T3 wakes this thread when a check fails, the required checks pass,
  someone else comments, or the branch starts to conflict with its base. A comment
  wake gets read and answered like a review finding; a conflict wake goes to a
  fresh fix implementer. On a checks wake, or at once without the T3 tools, run
  in the background:

  ```bash
  scripts/merge.sh --repo <owner/name> --pr <n> --run <id> --issue <n>
  ```

  It checks the merge test itself (the PR is open and not a draft, the review
  rounds the policy requires have settled, the head commit's checks are green),
  waits for CI through `ci-wait.sh`, squash-merges pinned to the green commit,
  and closes the issue when the base is not the default branch. It prints one
  line:
  - `merged ...`: log `run-end outcome=merged`.
  - `refused <reason>`: the reason says what is missing. Do that step, then run
    it again. Pass `--round2-skipped "<why>"` only when the commits after review
    round 1 were not review fixes.
  - `red ... log=<file>`: the file holds the failed steps' output; read it rather
    than querying `gh run view`. A failure the branch caused goes to a fresh fix
    implementer, then CI runs again, once.
  - A second `red`, a `red` from a cause outside the branch, or `timeout`: hand
    over as usual, unmerged. Call `unwatch_pull_request` first, so the thread
    returns to the human's inbox.
- The handover report (step 8) still happens in full: it is the only record the
  human gets.
- **Under `ship-epic`** (the launch message says so): the PR opens against the
  epic's integration branch, `epic/<n>`, and the merge lands there; `merge.sh`
  closes the issue, and the epic thread reads a closed issue as merged. The
  handover goes up as a comment on the issue after `run-end` and
  `usage-report.sh`. The run's **last action** is the `t3_thread_send` report the
  launch message specifies, with a `clientRequestId` of
  `ship-issue-<n>-<run id>-report-<k>`, where `<k>` counts this run's reports (1,
  then 2 after a resume; keep it in `run-state.md`), so a retried send does not
  report twice. It wakes the epic thread. A run that stops short posts the
  comment and sends the report too.
- **Resume.** A stopped run that is sent a resume message continues from
  `run-state.md` under the run id it already has: no second `run-start`. It logs
  a second `run-end` when it finishes, and the report takes the last one.
