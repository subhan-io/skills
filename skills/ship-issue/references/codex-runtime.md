# Codex collaboration runtime

Read this file when the available delegation surface is Codex collaboration tools such as
`spawn_agent`, `wait_agent`, `list_agents`, and `followup_task`.

## Capability mapping

- `spawn_agent` creates a fresh role agent but does not select Claude `opus` or `sonnet` models.
  State this substitution to the user once before the first spawn. Do not describe the spawned
  agent as Opus or Sonnet.
- `wait_agent` is the continuation mechanism. A child returning `completed` does not itself prove
  that the parent will be automatically re-invoked after the parent has ended its turn.
- `list_agents` is a status snapshot, not a completion waiter and not artifact validation.
- Use `followup_task` only to continue or correct the same role agent. Never use it to collapse
  sequential implementation chunks into one context.

## Waiting rule

After spawning an agent, keep the parent turn active and wait in bounded intervals. Send the user
a concise progress update at least every 60 seconds during ongoing work. Do not return a final
answer saying that an agent is still running unless the environment prevents continued waiting or
the user explicitly asks to pause.

When an agent completes:

1. Read its returned output.
2. Inspect every artifact the role was required to produce.
3. Check the worktree or GitHub state required by that step.
4. Mark the step validated only when its exit conditions hold.
5. Continue the parent workflow or stop at the human approval gate.

Use these phrases precisely in user updates:

- "The planner agent returned; I am validating its plan."
- "The plan is validated and ready for your approval."
- "Chunk N's agent returned; I am checking its handoff and verification evidence."
- "The PR is ready to merge" only after step 9's conditions hold.

Never use "finished" or "complete" without naming whether it refers to the agent, the validated
step, or the entire workflow.
