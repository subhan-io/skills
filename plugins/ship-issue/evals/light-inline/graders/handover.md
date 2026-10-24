---
type: llm
---

PASS if the final message is a handover that lists the task's acceptance criteria with a status for each, and reports the test command it ran with that command's result.
FAIL if the final message has no per-criterion status, or claims the tests pass without naming the command it ran.
