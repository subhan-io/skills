---
name: plan-explainer
description: >-
  Build and publish a self-contained HTML explainer page the human reviews from any
  device — UI mocks from the app's real design tokens, decision forks as selectable
  cards, a Copy-answers button. Use when presenting a plan for approval, showing
  design options or mocks, or putting open questions to the human that benefit from
  being seen rather than described.
---

# Plan explainer

One HTML page that lets the human approve or answer in one read. Show, don't
describe: the page's mocks and cards are the review surface; chat carries only the
URL and a summary.

Write the page as one self-contained file (inline CSS and JS, nothing external),
readable on a phone and in light and dark. Publish it with the `pr-media-upload`
skill and put the URL on its own line at the top of your message, with the file
path beside it. The URL is public but unlisted (random key, no auth, permanent) —
keep secrets off the page, and say "unlisted, permanent" when handing it over.

## What the page covers

Use judgement on structure and styling; drop what the plan does not need.

- **The ask** and the confirmed acceptance criteria, first.
- **What changes**, shown rather than described. UI work: static mocks built from the
  app's real design tokens, with declined alternatives beside the planned one, and
  anything the code and docs do not set labelled as invented. Everything else:
  before/after behaviour; code excerpts only where a decision turns on them.
- **Risks, verification, and what is out of scope**, briefly.
- **Open questions** as a form: each unsettled fork sits beside the mocks that show
  its options, as selectable cards plus an optional note. A sticky **Copy answers**
  button copies every question and chosen answer as plain text for the human to
  paste back into chat — never re-ask the same questions as chat prose.
- **Decisions already made**, consolidated in one place, so a later reader gets the
  same briefing the approver did.

Write for a strong engineer who knows this repo: skip the repo tour, the stack, and
the toolchain. Prose is ASD-STE100 Simplified Technical English.

## Revisions

A revision overwrites the same file — it always holds the current version — and
each upload is a fresh URL: name the new one and say the old one is stale. A
pasted-back answers block is an answer, not an approval; fold the answers in, say
what changed, then ask for the green light.
