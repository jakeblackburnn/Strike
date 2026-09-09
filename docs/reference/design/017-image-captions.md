# 017 — Image captions (`/caption("text")`)

**Status: shipped** (2026-08-23; candidate B chosen by Jack the same day,
implemented with the mechanics below). **Superseded** (2026-08-31) by
`docs/reference/design/018-image-captions-v2.md` — the single-command
quoted-string form and forward-wrap binding didn't survive first use (no
rich caption content, only one position); kept below as history, not the
current grammar.

## Problem

Images are inline-only (`![alt](src)`, note none — shipped with the base
grammar); there is no way to pair an image with a caption that stays coupled
to it under reflow. `docs/reference/STRIKEDOWN.md`'s taxonomy already flags
"images as blocks, figures, …" as TBD. The current example
(`docs/example/images.sx`) fakes a caption with a separate `/color(muted)`
paragraph below the image — visually similar, but not a caption: no
`<figure>`/`<figcaption>`, and nothing stops the two elements drifting apart
under `grid`/`skinny` reflow or a future PDF backend that reflows blocks
across columns/pages.

## Terminology

- **Caption command** — `caption("text")`, a *structural* command (like
  `collapse`/`citations`, `docs/reference/STRIKEDOWN.md`) carrying a string argument. First
  command to carry free-text data rather than an enum/int/percent.
- **Figure** — the element the command produces: a wrapper holding the bound
  content element plus a `<figcaption>`, analogous to how `citations()`
  produces numbered entries from data rather than styling an existing block.

## Candidates (for record — Jack chose B, 2026-08-23)

### A — Markdown title string: `![alt](src "caption")`
Reuses CommonMark's title syntax. Zero new grammar, but repurposes a slot
some renderers already treat as a hover tooltip — a silent meaning change for
any doc that already used titles that way (none currently do, per corpus
check below, but the ambiguity persists for authors coming from other
markdown tools).

### B — Directive: `/caption("text")` — **chosen**
Same family as `/skinny()`/`/color()`: a single-command directive applying to
the very next content element. Reads as "this next thing gets a caption",
consistent with how every other per-element adjustment already reads in
strikedown documents.

```
/caption("A red panda spotted at the sanctuary, 2024.")
![A red panda in a tree](panda.jpg)
```

### C — Adjacent-paragraph promotion
An image alone on its own paragraph followed by a plain paragraph promotes
both into one figure, no new syntax. Rejected: implicit adjacency is
ambiguous (a caption-less image followed by ordinary prose would need an
escape hatch) and breaks the "activates iff it parses cleanly" degradation
story — there's nothing to parse, only position to infer.

## Mechanics (as implemented)

- `caption` joins the `Command` enum. `parseCommand` grows the one case that
  takes a quoted string argument instead of an enum/int/percent — needs a
  minimal string-literal grammar (`"..."`, backslash-escaped quotes only,
  matching JSON string escaping rather than inventing new escape rules).
- It's **structural**, not styling (`Attrs.anyStyle` skips it, per the
  existing collapse/citations precedent): the emitter doesn't write it via
  `writeStyleAttr` — it shapes the emitted element, wrapping the bound
  content in `<figure>…<figcaption>{text}</figcaption></figure>`.
- Binds to **one** content element via the existing `/cmd()` desugar (a
  nameless one-section group) — works on an image today, and for free on any
  future block-level content element (a code block captioned as "Listing 3",
  a table captioned as "Table 1") without new machinery.
- `// figure` / `caption()` as a **group** command (captioning a whole
  multi-element run, e.g. an image plus a legend list) is explicitly out of
  scope for this note — single-command only, matching how `color()` and
  `skinny()` both shipped single-command first and only later got group-level
  treatment.
- Layout-level rule: N/A (not a layout command — no counter, doesn't
  interact with `grid`/`skinny` nesting; a captioned image nests inside a
  `grid` section exactly like an uncaptioned one does today).

## Degradation analysis

A document that never uses `/caption(...)` is unaffected — the directive
family already degrades to prose on any line that doesn't parse cleanly
(`docs/reference/STRIKEDOWN.md`'s "parses-cleanly" rule), so `/caption(` with no closing
quote, or a caption line with no next element, both fall through to a
literal paragraph starting with `/caption(`.

**Corpus check**: `grep -rn '/caption(' docs/` and `grep -rn '"[^"]*")\s*$' docs/**/*.sx` —
zero hits. No existing content starts a line with `/caption(`, and no image
currently uses a markdown title string, so candidate A's silent-repurposing
risk is moot for this repo either way.

## Decision

**Candidate B**, dictated by Jack (2026-08-23). `/caption("text")` — a
structural single-command directive, string argument escaped `\"`/`\\` only
(JSON-style, restricted to those two forms). Group-level captions and the
title-string form (A) are not adopted.

## Canonical examples

```
/caption("A caption.")
![c](cat.png)
```
→
```html
<figure class="sx-group sx-figure">
<div class="sx-group-sec">
<p><img src="cat.png" alt="c"></p>
</div>
<figcaption>A caption.</figcaption>
</figure>
```

Degradation (no closing quote — falls to prose, image un-wrapped):
```
/caption(nope)

text
```
→
```html
<p>/caption(nope)</p>
<p>text</p>
```

These are `src/render_html.zig`'s `"caption: wraps the bound image in a
figure with a figcaption"` and `"caption: bad args degrade the line to
prose"` tests verbatim; `src/strikedown.zig`'s `"caption: parses a quoted
string, rejects malformed ones"` covers the string-literal grammar directly.

## Future direction

- Group-level `// caption("...")` for captioning a multi-element run (e.g. a
  `grid(2)` of images sharing one caption) once single-element captions have
  shipped and been used for a while.
- Once the `:` alias namespace reopens (note 010), a caption-heavy document
  could alias `:fig caption("") skinny(70%) center` to cut repetition — not
  before aliases land generally.
- The string-literal grammar this note adds (quoted, escaped text as a
  command argument) is the first of its kind; other future commands wanting
  free text (e.g. an `alt()` override, a `title()` on a table) reuse it
  rather than each inventing their own quoting rule.
