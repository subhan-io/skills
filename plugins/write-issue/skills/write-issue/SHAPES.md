# Issue shapes

One shape per kind. Section names are fixed so the readers that parse them
(`ship-issue`, `ship-epic`, the survey) find them. Omit a section that would be
empty; never write "None". The examples are real Content Atlas issues after
their rewrite.

## Feature

```markdown
## Problem            (or ## Goal, for something new rather than something wrong)

What is wrong or wanted, from the user's side, with one real example.

## Done when

- [ ] Observable outcome.

## Out of scope

Adjacent work a reader might assume is included.

## Blocked by

- #n
```

Example, #905 (`feat(content): anchor shot descriptions to the creator and a video-level synopsis`):

```markdown
## Problem

Shot descriptions treat each shot as an unrelated image. The creator appears as
"the man" or "a person", and each shot repeats context that hasn't changed
instead of saying what changed:

> The man continues to look at the screen, his expression curious. […] The
> lighting is consistent with the previous shots.

The padding also goes into the visual embedding, which weakens retrieval.

## Done when

- [ ] The vision call knows who the creator is: their handle, plus their avatar
      as a labelled reference image when one is stored.
- [ ] Each analysed video has a two- or three-sentence synopsis and a list of
      recurring subjects. Per-shot text says only what changed, refers to
      subjects by name, and is one or two sentences long.
- [ ] The visual embedding text, the shots tab and the MCP visuals include the
      synopsis.
- [ ] Rows written before the change still load.

## Out of scope

Carousel OCR.
```

**Decisions needed.** A feature that waits on the human's choice adds
`## Decisions needed` above Done when: the options, one line each with its cost,
and the recommended one marked. Label it `ready-for-human` and title the
criteria `## Done when (once decided)`. Example: #860, serving resized
thumbnails (variants at ingest, resize at the edge, or Next's optimiser on the
VPS).

## Bug

```markdown
## Problem

What happens, what should happen, and how to reproduce it: the steps, input or
failing command. Quote the error. Say how it was found if it came from a review.

## Done when

- [ ] The repro now gives the right result, as a regression test.
```

Example, #669: "Undo a decision, make a different one, then replay the pre-undo
`expectedVersion`: the request returns `CONFLICT`." A likely fix goes in one
closing line as a suggestion the plan decides, never as code.

## Task

```markdown
## Goal

What has to exist afterwards, and why it is needed. A human task says why it
can't be delegated (an account, a device, a credential).

## Done when

- [ ] Checkable result. For a human checklist, each step's evidence: an ID
      recorded in a comment, a command that now succeeds.
```

Example, #885: Apple and Expo setup. Its criteria name the bundle id, the
Infisical path and the `eas whoami` check, because those are the deliverables.

## Research or spike

```markdown
## Question

The decision this research makes, and what it blocks. A spike says its time box
and its one output (a recommendation, a scored checkpoint).

## Known so far

The three to five findings the question starts from, each with the number that
matters. Link the reports, at a commit SHA if their branch is unmerged.

## Done when

- [ ] The owner records the spend cap and inputs here before any paid run.
- [ ] A dated report ends in promote, iterate or reject, naming the production
      issue to open on promote.
- [ ] Nothing in production changes.

## Out of scope
```

Example, #623: three experiments, each one question with the single result that
motivated it ("a manual crop raised one video from 56.0% to 83.6% F1"), and the
reports linked at the closed PR's commit.

## Epic

```markdown
## Outcome

What is true for the user when the epic is done. One line: this is a
coordination epic; ship the children, not the parent.

## Decisions

Product and architecture choices every child must respect, one line each.

## Contracts

Only while children are being built: the interfaces children meet at, appended
by the run that settles each one. ship-epic reads this section. Once every child
that needs a contract has shipped, cut it: the code holds it now.

## Children

1. #n: outcome (after #m; human)

## Done when

- [ ] Outcome-level criteria, not "all children closed".

## Out of scope
```

Example, #622: AutoShot replaces scdet. Five Decisions lines (detector, fallback,
hosting, storage, rollout), the evidence in two numbers with report links, and
ten children with their order and blockers. Research children (#623, #634,
#635) are separate issues, so the build closing never closes them.

## Content Atlas roadmap

The next Content Atlas roadmap items (taxonomy labelling, carousel data, the
ranking rework, label-effect statistics, the Source page, launch) are each an
epic or a feature. Research inside one, such as whether label effects are
significant at the corpus's size, is a research child with its own decision.
