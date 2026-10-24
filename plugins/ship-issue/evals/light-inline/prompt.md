---
description: inline arm of the `impl` experiment
tags: [light, impl]
max_turns: 80
timeout_seconds: 1200
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent]
env:
  EVAL_SHIP_ISSUE_ARM_IMPL: inline
---

Use the ship-issue skill with: eval afk base=main. Adhoc task: fix `avg` in `calc.sh`. `./calc.sh avg 2 4 6` must print `4` (the integer mean of its arguments, rounded down), and `./calc.sh avg` with no numbers must print `error: no numbers` on stderr and exit 1. Add checks for both cases to `./test.sh`, which is the repo's whole test suite.
