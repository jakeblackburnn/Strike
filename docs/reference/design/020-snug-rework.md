# 020 — Snug rework (`/snug()`, the partner-styling leak, and the chain-nesting CSS seam)

**Status: shipped** (2026-09-15; bugs reported and fix dictated by the user
the same day — see Decision. A third bug surfaced testing the fix for the
first two, same day, same note.)

## Problem

019-snug.md's `snug()` shipped 2026-09-14 with two bugs found the next day:

1. `/snug()` (the single-command form) was rejected outright — `//
   snug() ... // end` was the only way to write it, unlike every other
   command, which works both ways.
2. A styling command chained alongside `snug()` on the same opener (`//
   color(accent) snug()`, `// skinny(50%) snug()`) landed on the *outer*
   `<div class="sx-group sx-snug">` — which wraps *both* sections, the
   popped partner included. Since HTML/CSS styling (color, width, text-align)
   inherits to a wrapper's whole contents, this visibly changed the partner
   too: the exact thing snug is supposed to never do. Reported concretely as
   "the element it backward-attaches to somehow gets the [snug'ed element's]
   commands, for instance its color."

Fixing (1) exposed a third bug, found testing it the same day: `/snug()`
leading a `/cmd()` chain (`/snug() /color(muted) text`) correctly
backward-attached and correctly left the partner unstyled (bug 2's fix
holds) — but the seam it's supposed to tighten was gone. Reported as "/snug()
followed by /color(muted) doesn't work, it just does color muted and snug
dies."

## Terminology

Reuses **backward-attach** and **partner** from 018/019 unchanged.

## Root causes

1. `parseSingleCommand` rejected *every* backward-attach command
   unconditionally (`Attrs.backwardAttach()`), reasoning that a `/cmd()`
   line only ever wraps forward, so there's no preceding sibling to pop.
   That reasoning is right for `caption()` (see below) but not for `snug()`
   used as a chain's *first* token: the block that call produces is exactly
   what the caller (`parseBlock`'s caller, via `appendSibling`) pops a
   sibling for — the same mechanism a `//`-opened snug group already uses.
   The rejection just never let a `/cmd()`-produced block carry `snug` far
   enough to find out.
2. `emitSnug` passed the *whole* group's `Attrs` (all commands merged from
   the same `//` opener line) to `writeStyleAttr` on the shared outer div,
   the same pattern `emitCaption` uses for its `<figure>`. For `caption`
   that's correct — a caption and its image genuinely are one figure, and
   sizing/coloring the whole figure is a reasonable reading of `// skinny(50%)
   caption()`. For `snug` it's wrong: snug's entire premise (unlike
   caption's) is attaching to the partner *without being* the partner — the
   two stay visually separate elements, just close together.
3. Fixing (1) means a `/cmd()` chain led by `snug()` can now put a plain
   `.sx-group` wrapper div between the section and its real content (any
   command after `snug()` in the chain nests one, same as any other `/cmd()`
   chain — see `strikedown.zig`'s `parseSingleCommand` doc comment). The
   `shell.zig` CSS from 019 only reached a *direct* child
   (`.sx-group-sec:last-child > :first-child`) — sound for the `//`-opener
   merged form (no wrapper div ever sits in the way there), but for the
   chain form that selector lands on the wrapper div, which carries no
   margin of its own. The real element's own default browser margin then
   *collapses straight through* that zero-padding wrapper (ordinary CSS
   margin-collapsing behavior — nothing here ever resets it, by design;
   `docs/reference/UI.md`/019's own Problem section note the renderer relies
   on browser default margins throughout), landing back at the full,
   untightened gap: exactly "snug dies." Confirmed empirically (headless
   Chrome, computed `getBoundingClientRect`): the old selector left a 16px
   gap (the `<p>`'s own default margin) between partner and content; only
   the new selector below produces the intended ~2.4px (`.15rem`).

## Decision

Dictated by the user, 2026-09-15, via a direct bug report ("these are bugs,
fix them") — the fixes below are the natural, essentially forced reading of
that report; no real alternatives were weighed:

1. **`/snug()` single-command form**: valid, but only as the *outermost*
   (first) token of a `/cmd()` chain — the one whose returned block actually
   reaches a sibling list to pop from. `parseSingleCommand` gained an
   `is_root` parameter: true only for the call from `parseBlock`, false for
   the recursive call that resolves a chain's next token. The check changed
   from "reject any backward-attach command" to "reject `caption` always;
   reject `snug` only when `!is_root`." Nested (`/color(accent) /snug()
   text`) has no preceding-sibling list at that frame to pop from — it
   reverts that whole `/cmd()` chain to prose (the wrapping command's own
   line renders as literal text), same as any other chain that fails to
   resolve. Whatever precedes or follows is parsed fresh and independently,
   exactly as today for any other reverted chain — including the
   possibility that a freestanding `/snug()` immediately after the reverted
   line then validly (and separately) attaches to *that* leftover prose,
   same as it would to any other preceding paragraph. `caption()` keeps its
   blanket rejection, root or nested: its position argument implies
   deliberate figure/figcaption boundaries a `/cmd()` line can't express,
   which isn't about chain position.
2. **The partner is never styled**: `emitSnug` no longer shares one styled
   wrapper across both sections. When a partner exists (2 sections), the
   outer `<div class="sx-group sx-snug">` carries no style at all; the style
   from `attrs` (whatever commands were chained alongside `snug()`) lands
   only on section 1's own `sx-group-sec` wrapper — the snug body. Section
   0 (the partner) renders exactly as it would if there were no snug group
   at all. No partner (the degrade case, 1 section): unchanged, falls back
   to the plain `sx-group` div with `attrs`' style on it (nothing to
   protect there).
3. **The seam-tightening CSS reaches through chain wrapper divs**: the two
   `.sx-snug` rules changed from a `>` (direct-child) combinator to a plain
   descendant combinator with `*` — `.sx-group-sec:last-child > :first-child`
   became `.sx-group-sec:last-child *:first-child` (and the mirror for
   `:last-child`/`margin-bottom`). This matches every first/last-child down
   however many wrapper divs a `/cmd()` chain nests, not just the immediate
   one — including the real content element at the bottom of the chain,
   wherever it ends up. Redundantly matching the wrapper divs along the way
   is harmless: they get the same margin value, so collapsing settles on
   that one value regardless of how many layers repeat it. No change to the
   `//`-opener merged form (no wrapper div ever sits between the section and
   its content there, so the direct child was always also a descendant).

## Canonical examples

```
Title

/snug()
A subtitle.
```
→ (identical to the `// snug() ... // end` form)
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

The partner-styling fix — `Title` carries no color despite the chained
`color(accent)`:
```
Title

// color(accent) snug()
A subtitle.
// end
```
→
```html
<div class="sx-group sx-snug">
<div class="sx-group-sec">
<p>Title</p>
</div>
<div class="sx-group-sec" style="color:var(--accent)">
<p>A subtitle.</p>
</div>
</div>
```

Nested in a chain — reverts that command's own line to prose (the
freestanding `/snug()` that follows then independently attaches to the
leftover prose paragraph):
```
/color(accent)
/snug()
text
```
→
```html
<div class="sx-group sx-snug">
<div class="sx-group-sec">
<p>/color(accent)</p>
</div>
<div class="sx-group-sec">
<p>text</p>
</div>
</div>
```

`/snug()` leading a chain — attaches correctly, but what follows nests
inside section 1 (same as any other `/cmd()` chain), so the CSS fix has to
reach through the extra wrapper div to tighten the seam:
```
Title

/snug()
/color(muted)
Subtitle.
```
→
```html
<div class="sx-group sx-snug">
<div class="sx-group-sec">
<p>Title</p>
</div>
<div class="sx-group-sec">
<div class="sx-group" style="color:var(--muted)">
<div class="sx-group-sec">
<p>Subtitle.</p>
</div>
</div>
</div>
</div>
```

These are `src/render_html.zig`'s `"snug: /snug() single-command form
renders identically to // snug()"`, `"snug: the popped partner is never
styled, even when snug carries a color"`, `"snug: nested in a /cmd() chain
can't bind — the wrapping command's line stays literal prose"`, and `"snug:
/snug() leading a /cmd() chain wraps the rest in a nested group, partner
untouched"` tests verbatim; `src/strikedown.zig`'s `"snug: /snug()
single-command form backward-attaches"`, `"snug: /snug() with no preceding
sibling warns and degrades"`, and `"snug: nested (non-root) in a /cmd()
chain reverts that command to prose"` cover the parsing mechanics directly;
`src/shell.zig`'s `"snug CSS: descendant combinator, not just direct child,
reaches through a /cmd() chain's wrapper div"` locks in the corrected
selectors.

## Future direction

- Bubbling a nested chain's backward-attach up to the chain's outermost
  block (so `/color(accent) /snug() text` could mean "color the body,
  attach the whole thing to the preceding sibling") was considered and
  rejected here as unnecessary complexity for an unrequested case — put
  `snug()` first in the chain instead, which already expresses the same
  visual result via `/snug() /color(accent) text`.
- 019's own "Future direction" items (tunable tightness, a third
  backward-attach command) are unaffected by this note.
