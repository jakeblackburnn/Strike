# 006 — The `color` command (`color(role)`, `[text].color(role)`)

**Status: shipped** (2026-07-16; both syntaxes and the restriction posture
dictated by Jack — the inline postfix form is Jack's, and every ambiguous
interaction is resolved by *restriction*, see Decision. The role-name set and
non-layout nesting were chosen by Jack from AI-drafted alternatives the same
day.)

## Problem

Coloring text from plain text: a muted aside, an accent word, a de-emphasized
block. The reverted 0.0.1 feature (`:color brand #7c3aed` directives + a
`(brand)` block prefix) proved the demand but had the wrong model twice over:
it named **raw RGB values**, which fight the reader's theming — the shell
swaps eight seasonal palettes (`data-season` × `data-time` in `shell.zig`),
and a hex that reads on winter-evening's `#0d1626` vanishes on fall-morning's
`#faf6ef` — and it was a *settings language* in the `:` namespace, which Jack
has since redirected to command aliases (note 005, "Command status"). This
note returns color as a **command** speaking in **theme roles**.

## Terminology

- **Color role** — a named slot in the reader's theme, not a color value:
  `accent`, `muted`, `fg`. HTML emits `var(--<role>)`; each theme block in
  `shell.zig` defines what the role resolves to. A future backend (PDF) maps
  roles to its own palette.
- **Color span** — the inline form `[text].color(role)`: a run of inline
  content carrying a role.

## Decision (grammar and semantics)

Two positions, one vocabulary:

- **Block**: `color(role)` is a command — valid on group openers
  (`// note color(muted)`, combinable with other commands) and in
  single-command position (`/color(accent)` binds the next content element),
  riding the note 001/002 machinery unchanged. It lands as
  `Group.text_color`; HTML emits `color:var(--<role>)` on the `sx-group`
  wrapper, after any layout declarations.
- **Inline**: `[text].color(role)` — bracketed inline content immediately
  followed by `.color(role)`, parsed in the inline chain at `[` **after** the
  link form fails. Contents are inline-parsed like link text (bold, code,
  math inside all work). HTML: `<span class="sx-color"
  style="color:var(--<role>)">…</span>`.
- **Roles are exactly `accent`, `muted`, `fg`** — the theme variable names,
  no translation layer. `fg` exists to reset back to body color inside an
  already-colored region. Anything else (`color(red)`, `color(#fff)`,
  `color()`) is not a clean command / span and stays prose — the strict-typo
  rule. Surface roles (`bg`, `border`, `code-bg`, `sidebar-bg`) are *not*
  text roles and are deliberately absent.
- **`color` is the first non-layout command**: it never touches a
  `layout_depth` counter, so color-in-color nests freely with no warning
  (inner wins by CSS cascade — a muted box with an accent paragraph inside is
  meaningful, unlike grid-in-grid). This exercises the note 004 escape hatch
  ("a non-layout command simply won't touch a counter") for the first time.

### The restriction posture (dictated)

Every ambiguous interaction resolves by **doing nothing**, never by guessing:

- **No postfix on links.** `[label](url).color(accent)` — the link form wins
  the `[` (it is earlier in the inline chain), and `.color(accent)` stays
  literal prose. Coloring a link is currently inexpressible.
- **No links inside spans.** `[see [z](url)].color(muted)` — same reason,
  from the other side: the first-`]` scan hands the outer `[` to the link
  parser, which produces exactly what plain markdown produces today
  (byte-identical degradation).
- **No nested spans.** Brackets don't pair; the earliest `].color(` closes
  the span (`parseColorSpan` mirrors `parseLink`'s non-nesting scan) and the
  rest stays literal.
- **Elements that own their color keep it.** Links (`a{color:var(--accent)}`),
  blockquotes (`blockquote{color:var(--muted)}`), and code — now pinned via
  `code{color:var(--fg)}` in `shell.zig` — do not recolor inside a colored
  group or span. This isn't an accident to paper over: a CSS element selector
  always beats an *inherited* wrapper color, so the restricted behavior is
  what the platform does by default; we added only the `code` pin to make the
  rule uniform ("element-owned colors always win").

## Why roles, and the link to the reader's rendering colors

The renderer never learns what `accent` *is*. `render_html` emits a variable
reference; `shell.zig`'s theme blocks (8 = 4 seasons × morning/evening) each
define `--accent`/`--muted`/`--fg`, and the reader's pre-paint bootstrap
picks the block. Colored content therefore tracks live theme switches for
free, static exports stay self-contained (the variables ride the inlined
CSS), and `strike render --fragment` output degrades gracefully (an undefined
`var()` falls back to inherited color). When `:` aliases arrive, a color
command is nameable in a set (`:warn color(accent)` → `// warn`), which is
how the old "define a named color" ergonomics return — as an alias over a
role, never over an RGB value.

## The known interaction concerns, and the refactor that would lift them

Recorded so the restrictions are understood as chosen, not discovered:

1. **Inheritance vs element selectors.** Group/span color is an inline style
   on a *wrapper*; it reaches inner elements only by inheritance, which any
   element selector (`a`, `blockquote`, `code`) overrides. Restriction today.
2. **Coloring a link** is inexpressible (both syntactically and in CSS).
3. **Emphasis can't straddle a span boundary** (`[a **b].color(x) c**` — the
   `**` stays literal), same as links today.

The refactor direction, when lifting (1)/(2) is wanted: move element colors
in `shell.zig` to **derived variables** — `a{color:var(--link,
var(--accent))}`, `blockquote{color:var(--quote-fg, var(--muted))}`,
`code{color:var(--code-fg, var(--fg))}` — so a colored region can locally
re-derive them (`.sx-color{--link:inherit}` or the wrapper setting
`--link:var(--muted)`), letting owned elements *opt in* to region color
without ever losing to specificity. That pairs with the roadmap's sheet → CSS
compilation (emit classes + rules in the page `<style>` instead of inline
styles); until then inline styles keep fragments self-contained and the
restrictions keep semantics unambiguous.

## Degradation analysis

The block form rides note 001's activation rule (a `//`/`/` line must parse
cleanly; `color(red)` deactivates the line). The inline form is new surface:
`[…]` followed by `.color(` + role + `)` — in plain markdown a bare `[text]`
is already inert prose (reference links don't exist in strikedown), so
activation only changes documents that contain the exact postfix with a valid
role; near-misses (`[x].color(red)`, unterminated args, `\[` escape) stay
literal, and a real link followed by `.color(…)` renders as it always did.
Corpus check: zero hits for `color(` in `strikedown/` at decision time.

## Canonical examples

```
// note color(muted)

an aside

// end
```

→ `<div class="sx-group" style="color:var(--muted)">…</div>`

```
/color(accent)

### an accent heading
```

→ `<div class="sx-group" style="color:var(--accent)">…<h3>…</h3>…</div>`

```
a [single **word**].color(accent) here
```

→ `<p>a <span class="sx-color" style="color:var(--accent)">single
<strong>word</strong></span> here</p>`

Degradation: `[x].color(red)` and `[z](https://z.dev).color(muted)` render
their characters literally (the latter as a normal link + literal postfix).

## Future direction

- The derived-variable refactor above, if/when links or quotes should obey
  region color.
- `:` aliases naming color sets (`:warn color(accent)`); a `bg(role)` /
  highlight command for background tinting would be a new note (surface roles
  reopen the contrast question).
- Postfix commands other than `color` on `[…]` are deliberately not defined;
  if a second inline-applicable command appears, the grammar generalizes to
  "postfix command position" in one note rather than per-command carve-outs.
