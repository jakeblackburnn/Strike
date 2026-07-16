# 003 — The `skinny` command (`skinny(N%)`)

**Status: shipped, defaults provisional** (the feature — a content group
taking some percentage less space than the main body — was dictated by Jack,
2026-07-14. The concrete syntax choices below — `N%` meaning *resulting
width*, the required `%`, the 1–100 bounds, and the bare-`skinny()` default
of 75% — are AI-proposed and implemented pending Jack's review.)

## Problem

The first non-grid layout command: narrow a group (or, via `/skinny()`, one
element) relative to the main body column — pull-quotes, asides, centered
figures-to-be. Also the first command with an *optional* argument, setting
that precedent.

## Decision (grammar and semantics)

- `skinny(N%)` — the group renders at **N% of the body column width**,
  horizontally centered. `N` is an integer 1–100; the `%` is required.
- `skinny()` — bare form, defaults to **75%**.
- Anything else (`skinny(50)`, `skinny(0%)`, `skinny(150%)`, `skinny(x%)`)
  is not a clean command and deactivates the whole line — the strict-typo
  rule from note 001.
- Valid on group openers and in single-command position, alone or combined
  (`// g grid(2) skinny(80%)` = a narrower grid).
- `skinny` is a **layout command**: it creates a layout element and counts
  under the layout-level rule exactly like `grid`.
- HTML: `width:N%;margin-inline:auto` on the `sx-group` wrapper, after any
  grid declarations.

### ⚠️ Flagged for review: what does N mean?

Jack's phrasing was "some percentage **less** space than the main body". Two
readings:

- **A (implemented)**: `skinny(80%)` → the group is 80% *of* the body width.
  CSS-conventional; what an author who thinks in widths expects.
- **B**: `skinny(20%)` → 20% *less*, i.e. 80% width. Matches the phrasing
  literally; unusual as a control.

A was implemented. Flipping to B is a two-line change (`parseCommand` and
the spec/tests); the emitter is unchanged either way.

## Degradation analysis

`skinny` rides note 001's activation rule: it only ever appears inside a
`//` or `/` line that must parse cleanly, so no new prose is at risk. The
strict argument grammar (`%` required, bounds enforced) keeps near-misses
visible as prose rather than silently misrendering. Corpus check: no `//` or
`/` lines mentioning `skinny` existed in `strikedown/` at decision time.

## Canonical examples

```
// box skinny()

a narrow box paragraph

// end box
```

→ `<div class="sx-group" style="width:75%;margin-inline:auto">…</div>`

```
// g grid(2) skinny(80%)
```

→ `style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem;width:80%;margin-inline:auto"`

Degradation: `// g skinny(50)` (no `%`) is an ordinary paragraph.

## Future direction

- Alignment variants (flush-left/right instead of centered) as a separate
  command or argument — not baked in here.
- A responsive floor (don't shrink below readable width on narrow screens)
  is reader styling on the `sx-group` class in `shell.zig`, not language.
