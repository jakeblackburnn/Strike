# Design process

How design decisions get made and recorded in this repo. This document governs the
*process*; the documents it names govern the *decisions*. Where chat history, habit, or
memory disagree with these files, the files win.

## The boundary: language vs toolkit

Two different things get designed here, and they get different processes because their
mistakes cost differently:

- **strikedown** — the language. Syntax is near-permanent: a document written today must
  mean the same thing in every future version and every backend. Language design is
  therefore deliberate and written: proposed, analyzed, and decided *before*
  implementation, with the decision recorded.
- **strike** — the toolkit (reader, server, exporter, CLI). Toolkit design is iterative
  and judged by use; it is bounded by written principles, not specified in advance.

The rule for which side a feature is on: **it belongs to the language if it changes what
a document means; it belongs to the toolkit if it changes how documents are found,
navigated, served, or read.** The one sanctioned crossing point is `strike.yaml`'s
`header:` key — the reader may *name* which typography applies, never define it.

Features that straddle the line (e.g. an in-page TOC: reader chrome built on the
language's heading ids) are toolkit features, but any language-side accommodation they
need goes through the language process.

## Document map

| Document | Governs |
| --- | --- |
| `docs/reference/STRIKEDOWN.md` | The language spec — every form, its meaning, canonical examples. Implementation-independent: every sentence must stay true for the PDF backend. |
| `docs/reference/design/NNN-*.md` | One design note per language feature — the candidates considered and the decision made. History; the spec is truth. |
| `docs/reference/MODEL.md` | The internal model of record — the document tree, the pipeline, the taxonomy↔types mapping, and the extension recipes implementations follow. |
| `docs/reference/UI.md` | Reader chrome principles. |
| `docs/reference/STRIKE_YAML.md` | Reader/config reference. |

## When a design note is required

**Required** for anything that changes what a document means: new superset syntax, a new
directive, a new tree attribute, or a change to the semantics of an existing form.

**Not required** for: closing a standard-markdown gap (GFM is already the spec — 
implement to it and add the result to `STRIKEDOWN.md`), toolkit/UI/CLI changes, bug
fixes toward already-specified behavior, and refactors.

## Design note lifecycle

Notes live at `docs/reference/design/NNN-slug.md`, numbered sequentially, never deleted.

- **draft** — candidates and analysis exist; no decision yet. Nothing is implemented
  from a draft.
- **accepted** — the Decision section is written. Implementation may begin.
- **shipped** — implemented and tested; the canonical examples are merged into
  `STRIKEDOWN.md`. From here the note is a record, not a reference.
- **rejected / superseded** — kept, with a line saying why.

## Division of labor

This repo is developed with AI assistance; the process is shaped around that:

- **The human decides.** Every note's Decision section is dictated by the human. The AI
  never advances a note to accepted.
- **The AI diverges before the decision.** A draft presents 2–3 genuine syntax
  candidates with worked examples, a degradation analysis for each, and the edge cases —
  alternatives to choose between, not one proposal to approve.
- **The corpus is the validator.** Every syntax candidate is checked against the real
  documents in `strikedown/` for accidental activation — text that today is inert prose
  and would silently change meaning. A candidate that collides needs either a narrower
  trigger or a rejection note.
- **Degradation is a mandatory section.** Every superset form must be inert prose in
  documents that never activate it (the parses-cleanly precedent of `//` lines). A
  draft that cannot state its degradation story is not ready to decide on.
- **Spec examples are the tests.** Each canonical example in an accepted note becomes a
  parser test in `src/strikedown.zig` and an end-to-end test in `src/render_html.zig`,
  quoting the example.
- **Implementation follows the recipes** in `docs/reference/MODEL.md` ("Extension recipes") —
  the design note says *what*; the recipe says *how*.
