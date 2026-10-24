# ship-epic AFK mode

Read this file when the invocation says `afk`. Everything in `SKILL.md` applies;
this file adds what an unattended drain needs.

## Survey (step 1)

Call `t3_thread_list` with `titleContains: "ship-issue #"` and
`settled: false`. An unsettled thread whose issue has no report yet is a run
already in flight from an earlier invocation: it counts against the concurrency
limit, and its issue gets no second run.

The survey's `horizon` (the first open issue labelled `hitl`) bounds
the run: that issue remains eligible, every issue after it is outside this run,
and the survey already reports them as `beyond-horizon`, so concurrency cannot
cross the barrier.

## Ship (step 3)

Launch each pick as its own top-level **T3 thread** through the `t3-code` MCP server — a sidebar thread with a full live
transcript, bound to its own worktree. The launched run merges its own PR into
`epic/<n>`; the base branch stays the human's. In Claude Code the server's tools
can be deferred: load each `t3-code` tool this step names before its first call.

- **Preflight, once per run.** Call `orchestrator_capabilities`. Its
  `parentThreadId` is this thread's id: every run reports to it. From its
  `providers`, take the Claude provider instance and its Sonnet model id. When
  the tools are absent, stop and report: AFK needs a T3 Code build with the V2
  orchestrator. A launched thread cannot run with broader modes than this one,
  and a run merges unattended, so the result's `runtimeMode` must be
  `full-access` and its `interactionMode` `default`; otherwise stop and ask the
  human to switch this thread's modes.
- **Launch.** One `t3_thread_launch` per pick:

  ```json
  {"title": "ship-issue #<n>",
   "modelSelection": {"instanceId": "<claude instance>", "model": "<sonnet id>"},
   "workspaceStrategy": {"type": "worktree", "baseRef": "epic/<epic>",
                         "branch": "<branch>", "startFromOrigin": true},
   "message": "<launch message>"}
  ```

  T3 fetches, creates the worktree from `origin/epic/<epic>`, runs the project's
  setup script, binds the thread to the worktree, and then delivers the message.
  The launch message: "Invoke the ship-issue skill with: afk #<n>. This is a
  ship-epic run for epic #<epic>: open the PR against `epic/<epic>` and, once it
  is review-ready and green, merge it there. When it finishes, post the handover
  report as a comment on issue #<n>, then, as the run's last action, call
  `t3_thread_send` with threadId `<parentThreadId>`, mode `queue`, and message
  `ship-issue #<n> outcome=<run-end outcome> pr=<url> comment=<url>`." Append
  the database command when the pick needs one, then the epic context block.

  The launched thread is the run's orchestrator and runs on Sonnet; Fable only
  when the human asked for it, and the plugin's hook denies a Fable launch
  otherwise. Name the model in chat as you launch,
  and keep the returned threadId beside the issue number for the rest of the
  run. The launch has no retry key: after an error or a lost response, look for
  the thread with `t3_thread_list` before launching again.
- **Wait by ending the turn.** A run's report arrives in this thread as a queued
  message and starts the next turn, so after launching, end the turn. Each report
  turn re-runs the survey and picks again. A pick is review-ready only when its
  full verification and evidence gates passed, its review rounds finished under
  `ship-issue`'s review policy (step 7) with their fixes pushed, and its head
  commit's required checks ran and passed. The run merges through
  `ship-issue`'s `merge.sh`, which checks that test itself.
- **Heartbeat.** A run that crashes, or stops on a question, never reports. With
  the first launch, call `list_scheduled_tasks`; when no heartbeat for this epic
  exists, create one with `schedule_task`: title `ship-epic #<epic> heartbeat`,
  schedule `{"type":"interval","everyMs":3600000}`, bound to this thread, prompt
  "ship-epic heartbeat for epic #<epic>: check every in-flight run." On a
  heartbeat turn, call `t3_thread_list` with `titleContains: "ship-issue #"`,
  `settled: false` and `statuses: ["failed", "interrupted", "cancelled"]` to
  find the runs that died, then `t3_thread_read` each other in-flight thread:
  - `pendingRequestCount > 0`: the run waits on a question that AFK cannot
    answer. Park its sub-issue for an attended tick.
  - status `failed`, `interrupted` or `cancelled`: the run stopped short.
  - idle with no report: read its last messages. A run waiting on background
    work (an implementer, a review, a `watch_pull_request` wake for CI) says
    so; any other idle run stopped short.

  A run that stopped short is a failure (step 5). Interrupt nothing that is
  still working.
- **Resume a transient stop.** A run that stopped on a cause outside its work —
  a usage limit, a CI or GitHub outage — is resumed, never relaunched: once the
  cause has cleared, `t3_thread_send` its thread (mode `queue`) a message naming
  the cause and telling it to continue from `run-state.md`. It keeps its
  worktree, PR and run id, and reports again when it finishes.
- **Settle the thread once its handoff is complete.** The run links its PR to
  its own thread, and T3 settles a thread when its linked PR merges. When a
  report says `outcome=merged`, call `t3_thread_wait` on its thread (the report
  was the run's last action, so its turn ends within moments), then
  `t3_thread_organize` with `action: "settle"`; when T3 already settled it, there
  is nothing more to do. When the wait returns `timedOut: true`, leave the thread
  unsettled and say so. A run that stopped
  short — `outcome=stopped` or `pr-open`, not-AFK-eligible, a failed gate —
  keeps its thread unsettled: the marker is the sidebar's record that it needs
  a human, and its transcript is where they read why.
- Independent picks may run concurrently, **three in flight by default**
  (`afk 4` in the invocation changes it); a run is in flight from launch until
  its report arrives. A dependent pick waits until its blocker has merged
  into `epic/<n>` before branching. Never launch past the AFK run's `hitl` horizon.
- A run that reports not-AFK-eligible (criteria unclear from the issue, an
  unanswerable question) parks its sub-issue for an attended tick — never retry
  it AFK.

## Continue or stop (step 5)

Keep picking and merging. Refresh the survey after each report and launch
the next pick until either:

- every sub-issue in the epic has merged into `epic/<n>`, making the complete
  feature ready for the human's review; or
- the `hitl` horizon and every issue before it in build order have merged,
  making that checkpoint ready for the human.

Failures and AFK-ineligible issues stop the run for human attention;
never step around one to continue the feature. A stop launches nothing new; runs
already in flight finish and report. When no run is in flight, delete this
epic's heartbeat with `delete_scheduled_task`, so it does not wake a finished run.
