---
name: update-skills
description: >-
  Update every subhan-skills plugin to the latest marketplace version in both
  Claude Code and Codex, via each CLI's native plugin commands. Use when asked
  to update skills, refresh the subhan-skills marketplace, or pull the newest
  plugin versions.
---

# Update skills

Run the updater and report what changed:

```bash
bash scripts/update-skills.sh   # in this skill's directory; optional arg: marketplace name (default subhan-skills)
```

The script refreshes the marketplace in each CLI, updates each installed
Claude plugin at its own scope, and upgrades the Codex marketplace snapshot
(Codex plugins load from the snapshot, so that one step updates them all).
It prints Claude versions before and after, and the Codex plugin table.

The update is complete when the "after" versions differ from "before" (or
already matched the marketplace head) and the script exits 0. Report the
version change per plugin, and remind the human that running Claude and Codex
sessions load the new versions only on restart. On a non-zero exit, show the
failing command's output.
