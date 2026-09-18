# 022 — Paginated column flow

**Status: shipped, pagination policy provisional** (2026-09-18). Jake chose
Candidate A. Fine page-breaking controls remain open.

## Problem

`grid(n)` lays named group sections side by side; it does not flow one article
through successive columns or pages. An academic report needs a title and
abstract across the page, then body prose that flows through two columns. HTML
and PDF should read the same document tree. Today no page, column-flow, or
break primitive exists; CSS performs all layout measurement in HTML.

## Terms to settle

- **Flow columns**: one ordered stream is filled from the first column to the
  next. This differs from `grid(n)`, whose group sections are independent.
- **Page**: a bounded output surface. The browser's scrolling page is not a
  physical page; print HTML and PDF have one.
- **Span**: a block (title, abstract, figure) that crosses all flow columns.

This note asks where the flow instruction lives. Exact paper sizes and margins
can stay in `strike.yaml`'s `pdf:` settings; they do not change content order.

## Candidate A — a flow group

```sx
# A technical report

The abstract spans the page because it precedes the flow group.

// article flow(2)

## Introduction

Long prose fills the left column, then the right, then the next page.

## Results

More prose and figures continue in reading order.

// end article
```

`flow(2)` is a new group layout command. Its descendants remain one ordered
stream. HTML uses multi-column CSS for screen and print; PDF measures blocks
and advances a column or page when the next block does not fit. A full-width
figure inside the flow needs a separate `span()` design, or the author closes
and reopens the flow around it. The latter loses continuous balancing.

**Degradation:** A malformed `flow` opener is ordinary prose under the current
group parser; a valid `flow(2)` is a language change and old renderers would
ignore its layout attribute, leaving one ordered column. The text still reads
in source order. A group across most of a document is verbose, but gives
authors precise boundaries around full-width material.

## Candidate B — a document header flow setting

```sx
# A technical report

The abstract spans the page by a fixed rule for the first section.

## Introduction

Long prose flows through two columns.
```

```text
# paper.sxh
columns: 2
```

The header sets a default flow for the whole document. HTML and PDF can share
the setting without a new command or tree attribute. The hard question is
where a title, abstract, wide table, or appendix stops or starts that flow.
Making first heading/first paragraph special would be implicit document
semantics; adding exceptions later recreates Candidate A piecemeal.

**Degradation:** Unknown `.sxh` lines are ignored by current readers, leaving
one column. Source prose stays unchanged. This form has the weakest ability to
represent mixed-width academic papers.

## Candidate C — explicit page sections

```sx
// first page(2)

## Introduction

Content for one two-column page.

// end first

// second page(2)

## Results

Content starts on the next page.

// end second
```

`page(2)` gives an author a hard page boundary and a fixed column count per
page. HTML can show page boxes, and PDF can map each group to a physical page.
But edits that add one paragraph may overflow a page, so the renderer must
either continue on an implicit page (weakening the explicit boundary) or fail
layout. A long report becomes fragile to revise.

**Degradation:** As with A, a bad opener stays prose; an older renderer that
does not recognize `page(2)` preserves source order in one column. The intended
hard page boundaries disappear, so page-specific references would be unsafe.

## Cross-cutting edge cases

- **Reading order and selection:** DOM/PDF text order must remain source order,
  even if visual columns are balanced differently.
- **Unbreakable blocks:** Code, tables, images, equations, and captioned
  figures need a policy when taller than the remaining column, or the page.
- **Headings:** A heading should stay with at least the following paragraph;
  widow/orphan decisions require measurements the current model lacks.
- **Spans:** Title, abstract, wide table, and figure need full-width behavior.
- **Links and footnotes:** Internal anchors, citations, and future footnotes
  must survive moves across columns/pages.
- **Viewport changes:** Screen may show continuous columns while print/PDF
  paginates; the same source order must be preserved in both.
- **PDF geometry:** Existing `pdf.page_size` and `pdf.margin` are parsed but
  unused. The backend must validate them and define units before layout.

## Corpus check

On 2026-09-18, `rg` found no `page(`, `pages(`, `flow(`, or `columns(` on
command or alias lines in `docs/**/*.sx` and `docs/**/*.md`. The candidate
spellings therefore do not silently reinterpret any canonical example.

## Decision

Jake chose **Candidate A: `flow(n)` on a group** on 2026-09-18. It means one
source-ordered stream through `n` columns, then subsequent pages in a paged
medium. The first implementation accepts 2–4 columns; `flow` is group-only
and cannot combine with `grid` on the same opener. The title, abstract, and
other full-width material can precede or follow the flow group. An in-flow
span command is a separate decision and is not implied here.

This settles the language syntax and reading order. Exact pagination,
heading-with-next behavior, and oversize-block policy are renderer decisions
that require testing against real output; they may be specified here later.

## Canonical example

```sx
# Report

// body flow(2)

First.

Second.

// end body
```

The tree contains a heading followed by one group with `flow_columns = 2`,
one section, and two paragraphs in source order. HTML emits a group with
`column-count:2`; PDF fills the first column, then the next, then later pages.

## Implementation boundary

`013-command-realization.md` remains the home for how a particular content
element realizes a decided command. This note owns the flow command's meaning
and syntax. The HTML backend uses CSS columns; the native PDF backend must
implement equivalent source order.
