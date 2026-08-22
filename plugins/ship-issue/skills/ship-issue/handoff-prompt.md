# Writing the chunk handoff document

Adapted from [Matt Pocock's `handoff` skill](https://github.com/mattpocock/skills) and bundled
here so a `ship-issue` run hands off the same way whether or not that skill is installed on the
machine. If it **is** installed, invoke it (`Skill` tool, name `handoff`) and let it write the
document — then come back and check the document carries the required sections below, which are
specific to this run and which a general-purpose handoff has no way to know about.

## Who reads it

One agent, in a fresh session, with none of your context: whoever runs the next chunk of this
issue, or — if you were the last chunk — the orchestrator that opens the PR. Everything it will
ever know about your work, it reads here. Write for them. A status update aimed at a human who
was watching over your shoulder is not a handoff.

## Where it goes

**The run's state directory** — the `stateDir` the orchestrator gives you, which is
`<repo>/.claude/worktrees/ship-issue-<issue>.state/`. Name it `chunk-<n>-handoff.md`.

That directory sits *beside* the worktree, not inside it, and both facts matter. Inside the
worktree it would show as untracked and one `git add -A` would commit it into the PR diff — the
same leak the screenshot-harness rules exist to prevent. Beside it, under the already-gitignored
`.claude/worktrees/` path, neither the main repo nor the worktree can see it, and it still sits
next to the approved plan and the earlier chunks' handoffs where the next agent expects them.

Not the OS temp directory: these documents are the only continuity between chunks, and `/tmp` is
cleared out from under a run that spans a reboot. If the `handoff` skill picks its own path,
**copy the result into the state directory** and report that path.

## Rules

- **Do not duplicate what another artifact already holds.** The issue, the approved plan, your
  commits and the diff all exist, and the next agent can open any of them. Name them — path, URL,
  sha — rather than restating them. What belongs here is the part that exists nowhere else: what
  you learned by doing the work.
- **Assume nothing carries over.** No file is open, no command has been run, nothing you decided
  is remembered. "The usual place" and "as discussed" mean nothing to the reader. Spell out paths
  and names.
- **Report what happened, not what was supposed to happen.** Where the plan and your work diverged,
  the divergence is the most valuable thing in the document — the next agent is about to act on
  assumptions you have already disproved.
- **Redact anything sensitive** — API keys, tokens, credentials, personal data — even where you
  hit it legitimately in a config or a log. Say a value exists and where it lives; never paste it.
- **Suggested skills** — end with a short section naming the skills the next agent should invoke,
  and why. You have just learned which ones this repo actually needs.

## Required sections

- **Done** — what you built, in files and function names.
- **Deviations** — where you diverged from the plan, and why.
- **Verification** — the commands you ran and what they actually printed. Not "tests pass".
- **Screenshots** — the published URLs, each labelled with what it shows. If the chunk touched UI
  and there are none, say why in the words `un-capturable:` followed by the reason.
- **For the next chunk** — anything that changes their assumptions: interfaces you introduced or
  renamed, a helper worth reusing, a file structured differently than the plan describes, a gotcha
  that cost you time.
- **Stopped early?** — exactly where and why, and what state the worktree is in.
- **Suggested skills** — as above.

Read the finished document back once, as the stranger who will act on it. If a line only makes
sense because you remember the session, rewrite it.
