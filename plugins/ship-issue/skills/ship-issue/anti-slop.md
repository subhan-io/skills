# Code quality bar

Append this file to every implementation prompt. The diff is held to it at review.

- Every added line serves this chunk's criteria. Build the abstraction when the
  second caller exists, not before; ship configuration and flags only when the
  criteria name them.
- Search for an existing helper, hook, or component before writing a new one — the
  repo's version wins.
- Match the surrounding file's idiom: naming, error handling, comment density,
  formatting. The diff should read as if the file's original author continued it.
- Touch only the files the chunk names. Refactors, reformatting, and renames of
  untouched code go in their own future issue, not this diff.
- A comment states a constraint the code cannot show. Delete narration, restated
  signatures, and change-log commentary.
- Tests assert observable behavior, and existing tests stay as strong as you found
  them — a red gate is fixed at the root cause, never by loosening the assertion.
- Leave no dead ends: commented-out code, unused exports, debug output, and capture
  or harness artifacts are gone before you finish. `git status` and the diff show
  only the chunk.
