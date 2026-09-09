# Handoff

Append this file to every implementation prompt, after `anti-slop.md`. Your final
message is a handoff: the next session starts with none of your context, and the
orchestrator decides what runs next from what you write here. End the message with
these sections, in this order, each present even when its content is "none".

## Done

What landed, as files and function names. Point at the diff for detail; state here
only what the diff cannot show.

## Deviations

Where you departed from the chunk spec or the plan, and why. A deviation is the most
valuable line in this document: the next session is about to act on the assumption
you disproved.

## Verification

Each command you ran, its cwd, and its real output tail. "Tests pass" is not output.

## Remaining plan impact

Exactly one of:

- `none` — the remaining chunks stand as planned.
- `adjust: <what changes>` — the remaining chunks stand, but a fact you found changes
  how one of them is done: a renamed helper, a file structured differently from the
  plan, an extra caller. Name the chunk and the change.
- `replan: <why>` — a remaining chunk cannot be done as planned, or the criteria
  cannot be met on this approach. State what you found; propose nothing beyond it.

Choose from what you observed in the repo, not from doubt. A partial implementation
in your own chunk is a stopped chunk, not a plan impact.

## For the next session

Everything that changes the next session's assumptions and exists nowhere else:
interfaces you introduced, a helper worth reusing, a gotcha that cost you time and the
way around it. Write for a stranger: spell out paths and names.

## Repo gotchas

Facts about this repository that every future run should know and that no config
confesses: a command that lies, a suite that needs a shared port, a convention the
docs omit. `none` when the run taught you nothing new about the repo.
