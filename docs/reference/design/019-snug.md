# 019 — Snug (`// snug()` backward-attach seam-tightening)

**Status: shipped** (2026-09-14; decision dictated by the user the same day,
implemented with the mechanics below).

## Problem

Every block-level element gets the same default inter-block spacing (the
browser's own default margins — this codebase resets almost none of them).
That's the right default, but some pairs of blocks are conceptually one
unit read as two — a title and its subtitle, a label and the value under
it — and want to sit closer together than ordinary prose. Nothing in the
language could express that without borrowing unrelated semantics: wrapping
both in `caption()` implies a figure/figcaption relationship that isn't
true here, and `collapse()`/`grid()` add visible chrome or a layout the
author doesn't want.

## Terminology

Reuses **backward-attach** and **partner** from
`docs/reference/design/018-image-captions-v2.md` unchanged. This is the
second command to use the mechanism; `command.isBackwardAttach` and
`Attrs.backwardAttach()` generalize `appendSibling`'s guard (previously
hardcoded to `caption_pos != null`) so a third such command is a compile
error until classified, rather than a one-off `or` clause.

## Candidates

### A — Teach `caption()` a "no-figure" position

Add a fifth `CaptionPos` value that skips the `<figure>`/`<figcaption>`
wrapper and just tightens the seam. Rejected: conflates two different
purposes on one command (a real caption vs. a generic spacing utility), and
`caption`'s grammar and emitter already fork on four positions plus a split
percent — a fifth value that means "ignore all of that" is a worse fit than
a distinct, simpler command.

### B — New bare backward-attach command — chosen

`snug()`: no arguments, no positional data. It pops its preceding sibling
exactly like `caption()`, but the emitted wrapper is a plain
`<div class="sx-group sx-snug">` — the seam-tightening lives entirely in
`shell.zig` CSS, not in anything command-specific.

```
Title

// snug()
A subtitle.
// end
```

## Degradation analysis

A malformed `snug(...)` (any non-empty argument) fails `parseCommand`
and degrades the whole line to prose, per the standing rule — no new
degradation mode. `/snug(...)` as a single-command directive is rejected
outright (`parseSingleCommand`, via `Attrs.backwardAttach()`) for the same
reason `caption` is: backward-attach needs a full group, there's no "next
element" for a `/cmd()` line to mean.

The one new case this note adds: **`snug()` and `caption()` on the same
opener**. Both are backward-attach commands wanting the one popped-partner
slot — a malformed combination, structurally identical to `caption`'s own
`caption(top, 30%)` rejection (a split percent only meaningful with
`left`/`right`). Resolved the same way: the whole `//` opener line fails to
parse as a group (`parseGroupLine` returns `null`), so it — and everything
until the next real block boundary — renders as literal prose. No warning:
this is a syntax-level degradation like any other malformed argument
combination, not a runtime one (contrast with the no-partner case below,
which *does* warn, because the line parsed cleanly as a valid group and the
failure is discovered only at tree-assembly time).

No preceding sibling to attach to (the group opens the document, or
immediately follows another group's close): can't degrade to prose (the
`//` line already parsed as a valid `snug()` group) — renders as a plain
content group (no `sx-snug` wrapper) and a parse warning names what
happened. Identical shape to caption's own no-partner case; the two now
share one warning string (`"backward-attach group in '{s}': no preceding
element to attach to — rendered as plain content"`) and one code path.

**Corpus check**: `grep -rn 'snug(' docs/` — zero hits before this change.

## Decision

Dictated by the user, 2026-09-14, via three choices:

1. **Name and grammar**: `snug()`, bare only — no arguments. One fixed CSS
   tightness, like `center()`/`citations()`; a tunable-tightness argument
   was considered and deferred (see Future direction).
2. **Combination with `caption()`**: rejected outright — the whole opener
   line degrades to prose, not a silent precedence rule. Consistent with
   treating "two backward-attach commands on one opener" as a malformed
   combination rather than a policy decision to arbitrate.
3. **Wrapper and styling**: a plain `<div class="sx-group sx-snug">`
   (no semantic wrapper, unlike `caption`'s `<figure>`) with two
   `sx-group-sec` sections, reusing `emitSections` unchanged. The seam
   itself is tightened by two `shell.zig` rules keyed on `.sx-snug`,
   targeting only the boundary between the first section's last child and
   the second section's first child — `margin-bottom: 0` on the former,
   `margin-top: .15rem` on the latter (matching the alert-title's own tight
   gap, `.sx-alert-title`'s `margin: 0 0 .15rem` — the closest existing
   precedent for "a label sitting immediately above tightly-bound content").
   Zeroing only the trailing margin (rather than also zeroing the leading
   one) keeps the result deterministic regardless of what tag each side is.

## Canonical examples

```
Title

// snug()
A subtitle.
// end
```
→
```html
<div class="sx-group sx-snug">
<div class="sx-group-sec">
<p>Title</p>
</div>
<div class="sx-group-sec">
<p>A subtitle.</p>
</div>
</div>
```

No preceding element (degrades to a plain group, warns):
```
// snug()
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

Combined with `caption()` (degrades the whole opener line to prose, silently):
```
![a](a.jpg)

// snug() caption()

text

// end
```
→
```html
<p><img src="a.jpg" alt="a"></p>
<p>// snug() caption()</p>
<p>text</p>
<p>// end</p>
```

These are `src/render_html.zig`'s `"snug: backward-attaches, tight-seam
wrapper"`, `"snug: no preceding element degrades to a plain group"`, and
`"snug and caption combined: whole line stays prose"` tests verbatim;
`src/strikedown.zig`'s `"snug: backward-attaches to its preceding sibling
as section 0"`, `"snug: no preceding sibling warns and degrades to a plain
group"`, and `"snug and caption together: whole opener degrades to prose"`
cover the grammar and popping mechanics directly.

## Future direction

- A tunable tightness (an argument, or a `--sx-snug-gap` CSS variable) is
  deferred until a real use case asks for something other than the one
  fixed value — don't grow the grammar speculatively.
- `command.isBackwardAttach`/`Attrs.backwardAttach()` are now the
  extension point for a *third* backward-attach command, superseding
  018's forward-looking note (which pointed at the then-still-hardcoded
  `appendSibling` condition).
