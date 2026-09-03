---
name: ui-evidence
description: >-
  Capture and publish screenshots or video that prove a UI change — accurate shell
  and commit, permanent URLs for the PR body. Use when a change touches anything a
  user sees, when a review finding needs re-shot evidence, or when writing the
  capture instructions into an implementer's prompt.
---

# UI evidence

A change that touches anything a user sees ships with published screenshots. The
completion signal is visible pixels from the reviewed code, not a passing component
test or a plausible explanation. `un-capturable:` is the exceptional outcome after
the route matrix below is exhausted; it is not a shortcut around authentication or
fixture setup.

When an implementer agent (not you) does the capture, include this file's content in
its prompt.

## Capture route — exhaust the real options

Any route that renders the real change accurately is acceptable: an existing dev or
Storybook route, the harness browser/preview tools, a live dev server session, or a
throwaway Playwright script. Pick the cheapest one that shows the shipped pixels.

Before choosing it, separate the access layers:

- A preview banner such as `NO AUTH` usually means no network or proxy gate. It does
  **not** prove the application has no login. Drive the browser once and record whether
  the app itself redirects to sign-in.
- Treat the preview/server command's output as the authority for its database mode.
  When a later statement conflicts with that output, reconcile the conflict instead
  of changing the evidence conclusion. A failed login alone proves neither which
  database is attached nor that the account is absent.
- Never create accounts or fixtures in a read-only dev, production or PR database.
  Use a repository-sanctioned writable scratch database when the real end-to-end state
  is required and the app already documents how to provision, migrate, seed and delete
  one.
- If authentication or read-only data is the only blocker to visual evidence, build a
  temporary, uncommitted, dev-only harness route. Render the production component with
  fixture props inside the exact production shell/ancestor chain. A pure-component
  fixture proves shipped pixels, not persistence; pair it with the real behavioral
  smoke or integration test rather than pretending the fixture is end to end.

Two things disqualify a shot on every route:

- **Wrong shell.** The component must render inside the ancestor chain that supplies
  its layout, theme and design tokens in production. A leaf rendered under a bare
  dev shell is not evidence of the shipped UI. A protected route may be mirrored by
  an uncommitted public harness only when that harness explicitly mounts the same
  production shell.
- **Wrong commit.** The shot must come from the code being reviewed, not a preview
  deploy lagging the push or a stale session.

An application-auth redirect or a read-only PR database is not, by itself, an
`un-capturable:` reason. Use the fixture harness when the state can be represented
without lying about the pixels. Declare `un-capturable:` only after the existing
route, sanctioned scratch-data route and fixture-harness route are each unavailable
or inaccurate; name every route tried and the exact blocker.

## Evidence report — completion gate

Return a report with all of these fields; a parent workflow must reject a report
that omits one:

```text
reviewed HEAD: <sha>
real route: <attempt and observed result, including DB mode and app auth>
scratch route: <attempt/result, or exact reason unavailable>
fixture harness: <attempt/result, or exact reason inaccurate>
published: <permanent URLs>
```

When no route can truthfully render the state, replace `published:` with
`un-capturable:` and keep the three route entries. Tests may accompany the report
as behavioral evidence, but cannot occupy `published:` or justify skipping a route.

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
