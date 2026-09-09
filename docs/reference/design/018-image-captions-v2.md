# 018 — Image captions v2 (`// caption(pos)` backward-attach)

**Status: shipped** (2026-08-31; decision dictated by Jack the same day,
implemented with the mechanics below). Supersedes
`docs/reference/design/017-image-captions.md`.

## Problem

017 shipped `/caption("text")`: a single-command directive wrapping the
*next* content element, with the caption text as a quoted-string argument. In
use this had three problems: (1) no default styling existed for
`<figcaption>` at all — it rendered as plain body text; (2) the caption could
only ever sit below its image, with no way to place it above or to the side;
(3) a quoted-string argument caps caption content to one escaped line — no
bold, no links, no multiple paragraphs.

## Terminology

- **Backward-attach** — a group that binds to its immediately *preceding*
  sibling block rather than wrapping what follows it, the opposite of every
  other group/command in the language. New to this note.
- **Partner** — the block a caption group backward-attaches to (the image,
  typically); becomes section 0 of the resulting two-section group, with the
  caption's own content as section 1.

## Candidates

### A — Keep forward-wrap, add a position argument

`/caption("text", left)` or similar: same binding as 017, just a second
argument for placement. Rejected — doesn't fix the core problem (caption
content still capped to one quoted-string argument, no rich content), and a
`/cmd()` single-command directive still can't hold multi-line/multi-block
caption text no matter what arguments it grows.

### B — Backward-attach `//` group — **chosen**

The caption command's argument list holds only placement (`top`/`bottom`/
`left`/`right`) and, for side positions, a width split. The caption *text*
becomes ordinary group content, and the group attaches to its immediately
preceding sibling at parse time rather than wrapping the next one:

```
![a red panda](img.jpg)

// caption()
A red panda spotted at the sanctuary, **2024**.
// end
```

Reads naturally in source (the caption visibly follows its image) and gives
captions the same rich-content freedom as every other group.

## Degradation analysis

A `// caption(...)` opener line that doesn't parse cleanly (bad position
keyword, a split percent combined with `top`/`bottom`, an out-of-range
percent, a missing `%`) degrades the whole line to prose, per the standing
"parses-cleanly" rule — no new degradation mode invented for this. The one
genuinely new case: a caption group with **no preceding sibling** to attach
to (it opens the document, or immediately follows another group's close).
This can't degrade to prose (the `//` line already parsed cleanly as a valid
caption group) — instead it renders as a plain content group (no `<figure>`/
`<figcaption>`, just the caption's own content) and a parse warning names
what happened, the same shape as an existing precedent: a `grid(n)` whose
section count doesn't match `n` still renders, with a warning, rather than
erroring.

**Corpus check**: `grep -rn '/caption(' docs/` — only `docs/example/images.sx`
and `docs/example/commands.sx`, both rewritten as part of this change.

## Decision

Dictated by Jack, 2026-08-31, via three choices:

1. **Binding**: backward-attach (candidate B). A caption group pops its
   immediately preceding sibling block (one block, not a run) and rebuilds
   itself as a two-section group — section 0 the popped partner, remaining
   section(s) the caption's own parsed content. No preceding sibling: warn,
   render as a plain group (content only, no figure).
2. **Position grammar**: `caption()` (bare) = `bottom`, matching 017's only
   visual behavior. `caption(top)` / `caption(bottom)` / `caption(left)` /
   `caption(right)` name the other placements.
3. **Side split**: `caption(left, N%)` / `caption(right, N%)` — the percent
   is the caption column's share of the figure's width; omitted, it defaults
   to 30%. A percent combined with `top`/`bottom`, or given with no position,
   is a malformed combination — the whole directive degrades to prose (no
   new degradation rule; matches how every other malformed command argument
   already fails the whole line).

The old `/caption("text")` single-command form is **removed outright** — no
dual grammar. `/caption(...)` is now grammatically rejected as a
single-command directive (a `/cmd()` line wraps *forward*; backward-attach
needs a full group, so there is no "next element" for it to mean anything);
any such line degrades to prose.

**Default styling**: the figcaption is smaller (`.9em`) and muted
(`var(--muted)`, the same role `color(muted)` resolves to) by default, in
every position — a `shell.zig` default rule, not a per-instance style (it's
not driven by any command argument).

**Side-caption layout**: `left`/`right` figures become a flex row (image
column + caption column sized by the split); the caption column is itself a
flex column with `justify-content: flex-end`, so caption content shorter than
the image's height sits at the bottom of its column rather than floating to
the top. `top`/`bottom` figures are a flex column; visual order for `top`
comes from CSS `order` (the emitted HTML's child order is always
partner-then-caption, regardless of position) rather than from reordering the
markup — keeps the emitter's caption-rendering logic identical across all
four positions. Noted, not solved, in this pass: for `top`, DOM order and
visual order diverge, which is an accessibility tradeoff for anything that
reads DOM order rather than rendered order.

## Canonical examples

```
![c](cat.png)

// caption()
A caption.
// end
```
→
```html
<figure class="sx-group sx-figure sx-figure-bottom">
<div class="sx-group-sec sx-figure-body">
<p><img src="cat.png" alt="c"></p>
</div>
<figcaption>
<p>A caption.</p>
</figcaption>
</figure>
```

Left position with an explicit split:
```
![c](cat.png)

// caption(left, 45%)
A caption.
// end
```
→ same shape, `class="... sx-figure-left"` and
`style="--sx-caption-split:45%"` on the `<figure>`.

No preceding element (degrades to a plain group, warns):
```
// caption()
text
// end
```
→
```html
<div class="sx-group">
<div class="sx-group-sec">
<p>text</p>
</div>
</div>
```

Malformed combo (degrades the whole line to prose):
```
// caption(sideways)

text

// end
```
→
```html
<p>// caption(sideways)</p>
<p>text</p>
<p>// end</p>
```

These are `src/render_html.zig`'s `"caption: backward-attaches to the image,
one figure per position"`, `"caption: left/right positions carry the split
percent as a style var"`, `"caption: no preceding element degrades to a
plain group, no figure"`, and `"caption: bad args degrade the line to
prose"` tests verbatim; `src/strikedown.zig`'s `"caption: position/split
grammar, and malformed combos degrade"` and the backward-attach tests cover
the grammar and popping mechanics directly.

## Future direction

- A `:` alias (`:fig`) once the alias namespace reopens (note 010), to cut
  repetition on a caption-heavy document (`:fig caption(left, 30%) skinny(70%)`).
- The paren-depth-aware opener-line tokenizer this note adds (so
  `caption(left, 30%)`'s internal space doesn't get mistaken for a token
  boundary) is general — any future command taking a comma-separated
  argument list benefits, not just caption.
- Backward-attach is a new binding direction in the grammar; if a second
  future command wants it, this note's `appendSibling` mechanism is the
  place to extend, not a one-off.
