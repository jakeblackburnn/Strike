# 005 — The `center` command (`center()`)

**Status: shipped** (the feature — center-align text within the surrounding
layout element — was dictated by Jack via a `/center()` usage example,
2026-07-16; command status resolved by Jack the same day, see below. The
remaining choices — no arguments accepted, the `text-align:center` emission —
are AI-proposed and implemented pending Jack's review.)

## Problem

Centered text from plain text: title blocks, centered headings inside grid
cells, captions-to-be. Jack's example (test.md) uses `/center()` on headings
inside a `grid(2)` group — alignment of a single element within its cell.
Unlike `grid`/`skinny`, this command changes *text alignment inside* the
element, not the element's own box.

## Decision (grammar and semantics)

- `center()` — text within the group (or, via `/center()`, within the one
  bound element) is center-aligned. Centering is relative to the surrounding
  layout element: the grid cell, skinny column, or body the group sits in.
- **No arguments**: `center(5)`, `center(x)` are not clean commands and
  deactivate the whole line — the strict-typo rule from note 001. (If
  alignment variants ever arrive, they are a future design note — perhaps
  `align(left|right|center)` superseding this, or arguments here.)
- Valid on group openers and in single-command position, alone or combined
  (`// g skinny(60%) center()` = a narrow centered-text column).
- `center` is a **layout command**: it counts under the per-command
  layout-level rule (note 004) — center inside center is redundant nesting
  and is stripped with a warning, like grid-in-grid.
- HTML: `text-align:center` on the `sx-group` wrapper, after any grid/skinny
  declarations. Inherited CSS, so everything inside centers unless a deeper
  element overrides it.

### Command status (resolved 2026-07-16)

Text alignment arguably straddles the content/style split — is it a layout
command or a typography setting? Resolved by Jack's redirection of the `:`
namespace the same day: `:` is for **command/command-set aliases**, not a
separate settings language, so commands are the only vocabulary and `center`
stays one (an alias like `:title center() skinny(60%)` could then name it).

## Degradation analysis

`center` rides note 001's activation rule: it only appears inside a `//` or
`/` line that must parse cleanly, so no new prose is at risk. The no-argument
grammar keeps near-misses visible as prose. Corpus check: no `//` or `/`
lines mentioning `center` existed in `strikedown/` at decision time.

## Canonical examples

```
/center()
### a centered heading
```

→ `<div class="sx-group" style="text-align:center">…<h3>…</h3>…</div>`

```
// box skinny(60%) center()

narrow centered text

// end box
```

→ `style="width:60%;margin-inline:auto;text-align:center"`

Degradation: `/center(5)` is an ordinary paragraph.

## Future direction

- `left`/`right` alignment (or one `align(...)` command) when a use case
  appears; `center()` stays as-is or becomes sugar for it.
