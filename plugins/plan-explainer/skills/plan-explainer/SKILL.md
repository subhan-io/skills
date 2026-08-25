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

Copy `explainer-skeleton.html` (in this skill's directory) to your working file and
fill every `FILL:` comment. The page is done when no `FILL:` comment remains and it
opens as a complete page with no broken section. Then publish it with the
`pr-media-upload` skill and put the URL on its own line at the top of your message,
with the file path beside it. The URL is public but unlisted (random key, no auth,
permanent) — keep secrets off the page, and say "unlisted, permanent" when handing
it over.

## Content rules

- **Prose is ASD-STE100 Simplified Technical English.** One idea per sentence, under
  20 words, active voice, present tense, the same word for the same thing every
  time, exact code identifiers.
- **Written for a strong engineer who knows this repo.** Open with the ask and the
  confirmed acceptance criteria, then only what changes and the decisions behind it.
  Skip the repo tour, the stack, and the toolchain.
- **Show each piece of work.** UI work: static mocks built from the app's real
  design tokens, light and dark, with declined alternatives beside the planned one.
  Everything else: before/after behavior. Plain code excerpts appear only where a
  decision turns on them.
- **Ask via the form, not prose.** Each unsettled fork is a question block beside
  the mocks that show its options: selectable cards (mock cards where the question
  is visual, text where it is not), an optional note field, and the sticky one-line
  **Copy answers** button that copies every question and chosen answer as plain
  text. The human pastes that block back into chat — never re-ask the same
  questions as chat prose.
- Consolidate every decision already made in the endnotes, so a later reader gets
  the same briefing the approver did.

## Revisions

A revision overwrites the same file — it always holds the current version — and
each upload is a fresh URL: name the new one and say the old one is stale. A
pasted-back answers block is an answer, not an approval; fold the answers in, say
what changed, then ask for the green light.
