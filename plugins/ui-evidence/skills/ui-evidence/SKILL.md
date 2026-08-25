---
name: ui-evidence
description: >-
  Capture and publish screenshots or video that prove a UI change — accurate shell
  and commit, permanent URLs for the PR body. Use when a change touches anything a
  user sees, when a review finding needs re-shot evidence, or when writing the
  capture instructions into an implementer's prompt.
---

# UI evidence

A change that touches anything a user sees ships with published screenshots. If the
state genuinely cannot be produced, the report says **un-capturable:** and why — the
shots never quietly go missing, and that reason travels into the PR body so the
reviewer never guesses whether shots were skipped or impossible.

When an implementer agent (not you) does the capture, include this file's content in
its prompt.

## Capture route — use judgement

Any route that renders the real change accurately is acceptable: an existing dev or
storybook route, the harness browser/preview tools, a live dev server session, or a
throwaway Playwright script. Pick the cheapest one that shows the shipped pixels.

Two things disqualify a shot on every route:

- **Wrong shell.** The component must render inside the ancestor chain that supplies
  its layout, theme and design tokens in production. A leaf rendered under a bare
  dev shell is not evidence of the shipped UI.
- **Wrong commit.** The shot must come from the code being reviewed, not a preview
  deploy lagging the push or a stale session.

When no cheap route reaches the state, fall back to the full recipe: a temporary,
uncommitted, dev-only harness route seeded with fixture data in the app's own data
layer (no network mocking, no product-code changes), captured by a throwaway
Playwright script.

## Gotchas that hold on every route

- Shoot desktop at 1440×900. When the change is layout-sensitive, also shoot mobile
  at an explicit 402×874 viewport (iPhone 17 Pro) — not Playwright's
  `devices["iPhone 17 Pro"]`, whose height subtracts Safari's chrome.
- Wait on a real selector before shooting, never a sleep — blank and mid-skeleton
  shots come from shooting early.
- Turn off the framework's floating dev indicator (Next.js draws one) or the
  evidence ships with a widget on it.
- Run any dev server you start on an ephemeral port, record its PID, and stop it
  with `kill "$devpid"` — a `pkill -f <port>` matches your own shell and kills the
  session.
- A throwaway script outside the repo can't `import` the app's Playwright: anchor a
  `createRequire` at the app's `package.json` and `require("@playwright/test")`.
- **Publish before you delete.** Upload each image with `pr-media-upload` and record
  the URL first; a deleted PNG means retaking the shot from scratch.
- Tear down what you built: harness route, capture script, images, dev server.
  `git status` shows nothing from the capture — check, don't assume.

## Embedding

Images in a PR body or comment as `![alt](url)`; video as
`<video src="url" controls width="640">` on its own line. Later pushes that change
the UI (review fixes included) refresh the body's shots.
