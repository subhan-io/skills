---
description: inline arm of the `plan` experiment
tags: [deep, plan]
max_turns: 150
timeout_seconds: 2700
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent]
env:
  EVAL_SHIP_ISSUE_ARM_PLAN: inline
---

Use the ship-issue skill with: eval afk base=main. Adhoc task: notes need tags and a creation time. `./notes.sh add [-t tag]... <text>` records the note with its tags and the current UTC time, and `./notes.sh list [-t tag]` prints `<n>: <text> [tags]`, filtered to one tag when `-t` is given. Users already have notes files in today's format (one note per line, no header), and none of those notes may be lost or changed: the first run of any command on an old file converts it to the new format, giving old notes no tags and an unknown time. The new format must carry a version marker so a later format change can tell the versions apart. `./test.sh` is the repo's whole test suite; extend it to cover tagging, filtering, and the conversion of an old file. Plan it at the deep tier.
