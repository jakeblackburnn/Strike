# 012 — The `wide` command (`wide(N%)`)

**Status: shipped** (decision dictated by Jack, 2026-07-25)

## Problem

Layout can narrow a group (`skinny`) but never widen one. Anything that wants
more room than the reading column — a wide table, a figure, a full-bleed
aside, a grid of three that suffocates at 44rem — has no spelling. The body
column is a ceiling, and the language's only width control moves in one
direction.

## Terminology

- **Body column** — the main reading column a document renders into (the HTML
  backend's `.content`, `--content-width` wide). Both width commands are
  expressed as a percentage of it.

## Candidates

### A — `wide(N%)`, N above 100

```
// figure wide(150%)

a table that needs the room

// end figure
```

The exact mirror of `skinny`: the same argument shape, the same meaning
(percentage *of* the body column), just the other side of 100%. One reading
to learn for both commands, and the pair covers the whole width axis
continuously. Costs a ceiling — a percentage with no upper bound would let a
document render itself off the page.

### B — `wide(N%)`, N a fraction of the *extra* space

```
// figure wide(50%)
```

`0%` is the body column, `100%` is the full available width, and N
interpolates. Self-clamping (no ceiling needed), and `wide(100%)` reads as
"full bleed" without the author knowing how wide the reader's column is. But
N now means something different in `wide` than in `skinny` — the same
argument shape with two readings, which is exactly the trap `skinny`'s own
note flagged when it chose "percentage *of*" over "percentage *less*".

### C — bare `wide()` only

```
// figure wide()
```

Full-bleed, no argument, nothing to bound. Simplest possible spec; gives up
intermediate widths entirely, and a later `wide(N%)` would have to pick a
reading anyway.

## Degradation analysis (mandatory)

All three candidates ride note 001's activation rule: `wide` means something
only inside a `//` opener or `/wide(…)` line that parses cleanly, so no prose
is at risk in any document that never writes one. The strict argument grammar
keeps near-misses visible: `wide(150)`, `wide(x%)`, and (in candidate A)
`wide(100%)` or `wide(300%)` all fail `parseCommand` and deactivate their
whole line, leaving it an ordinary paragraph.

**Corpus check** (2026-07-25): zero hits for `wide(` across `strikedown/` and
`docs/`.

## Decision

**Candidate A.** Dictated semantics:

- `wide(N%)` — the group renders at **N% of the body column width**,
  centered, bleeding evenly into both margins. `N` is an integer **101–200**;
  the `%` is required.
- `wide()` — bare form, defaults to **125%**.
- Anything else deactivates the whole line: `wide(150)` (no `%`),
  `wide(100%)` and below (that is `skinny`'s range), `wide(300%)` (above the
  ceiling), `wide(x%)`.
- Valid on group openers and in single-command position, alone or combined.
- `wide` is a **layout command** with its own layout-level counter:
  `wide`-in-`wide` is stripped with a warning, while `skinny` inside `wide` is
  legal and meaningful (narrowing something within a widened region says
  something real).
- **One width attribute, two spellings.** Both commands write the single
  `Attrs.width_pct` field, and the grammar keeps their ranges disjoint: a
  value ≤ 100 was written by `skinny`, > 100 by `wide`. That invariant is what
  `hasCommand`/`clearCommand` read, and it makes the two commands naturally
  mutually exclusive on one opener — `// g skinny(50%) wide(150%)` is legal
  and the last one wins.
- HTML: `width:N%` with `margin-inline:calc((100% - N%) / 2)`. Auto margins
  compute to zero once a box overflows its container, which would push a wide
  group off to one side; the explicit negative margin bleeds it evenly.
  `skinny` keeps `margin-inline:auto`.

## Canonical examples

```
// figure wide()

a

// end
```

→
```html
<div class="sx-group" style="width:125%;margin-inline:calc((100% - 125%) / 2)">
<div class="sx-group-sec">
<p>a</p>
</div>
</div>
```

Combined, in the declaration order `skinny` already occupies (grid, then
width):

```
// g grid(2) wide(150%)
```

→ `style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem;width:150%;margin-inline:calc((100% - 150%) / 2)"`

Separate counters — narrowing inside a widened group is never stripped:

```
// outer wide(150%)

// inner skinny(50%)
a
// end

// end outer
```

→ the inner group keeps `width:50%`, no warning.

Degradation: `// g wide(100%)`, `// g wide(300%)`, and `/wide(150)` are all
ordinary paragraphs.

## Future direction

- **A viewport clamp** is reader styling on `.sx-group` in `shell.zig`, not
  language: a wide group on a narrow screen should stop at the viewport
  rather than scroll the page. The same "responsive floor" note 003 deferred
  for `skinny`, from the other end.
- The 200% ceiling is a backend judgement about what stays readable, not a
  language constant; a backend with a different page geometry (PDF) may pick
  its own.
- Alignment variants (bleed left only, bleed right only) stay open, as they
  do for `skinny` — a separate command or argument, not baked in here.
- `wide` is a natural target for a command alias (note 010): `:full-bleed
  wide(200%)`.
