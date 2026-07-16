# Strikedown — the language

The spec of record for strikedown (`.sx`), a typography-first superset of
markdown. Every form, its meaning, and its canonical examples live here;
`docs/design/NNN-*.md` records how each decision was reached (history), and
this file is what wins when they disagree. Everything in this document is
implementation-independent: each sentence must stay true for every backend
(HTML today, PDF planned), so nothing here names tags, CSS, or files.

Two principles govern everything below:

- **One flavor.** Plain markdown is strikedown's subset. `.md` and `.sx`
  mean the same thing everywhere; there are no dialects and no flags.
  Superset features are additive.
- **Degradation.** Every superset form is inert prose in a document that
  never activates it. A markdown document written anywhere renders the same
  under strikedown, byte for byte of meaning. Each form's activation rule
  below *is* its degradation story: whatever fails the rule is ordinary
  text.

## The element taxonomy

Every block-position construct in a document is one of:

- **Content element** — something the reader reads. Today that means the
  **text elements** (heading, paragraph, blockquote, list, code block,
  table, display math, horizontal rule); other content elements (images as
  blocks, figures, …) are TBD. A *text element* is a piece of text on a
  line — a heading, or a normal line of prose. Consecutive normal text
  lines merge into **one** text element (this includes `>` blockquote
  lines — see "Blockquotes"); a blank line separates them.
- **Layout element** — a *created* thing: layout commands make them.
  Layout elements dictate how content elements are organized — they hold
  content, they are not content. The **main body of the document is itself
  the top-level layout element**. Layout elements nest, but **each layout
  command applies at most once along any chain of containing layout
  elements**: no grids inside grids, no skinny inside skinny — while a
  skinny element inside a grid cell is fine. (Enforcement: a repeated
  command still forms its group, but that command is ignored and a warning
  is emitted; other commands on the same opener are untouched. This is the
  **layout-level rule**.)
- **Directive** — a line addressed to the renderer rather than the reader.
  Directives emit nothing themselves; they configure, bracket, or create
  the above.

**Groups** sit between the taxa: a group (`//` lines, below) is a *named
container* bracketing a run of content elements into sections. A group with
no layout commands is only a container — it may nest freely and creates no
layout element. A group given layout commands *becomes* a layout element,
and the layout-level rule applies to it.

## Directives

Three directive families, distinguished by their first characters. In each,
the activation rule is strict, so the family marker alone never changes
meaning — prose that happens to start with `//`, `/`, or `:` stays prose.

### Group directives — `//`

A `//` line (the marker must be followed by a space or end-of-line) brackets
content into a group. Grammar:

| Line | Meaning |
| --- | --- |
| `// <name> <command>*` | opener: named group |
| `// <command>+` | opener: nameless group (first token has parens) |
| `// --` | separator: next section of the innermost open group |
| `// end` / `// end <name>` | closer: closes innermost; a given name must match it |
| `//` (bare) | closer: same as `// end`, only meaningful while a group is open |

- A **name** is one bare token of `[A-Za-z0-9_-]+`; `end` and `--` are
  reserved. A **section** is the run of content elements between
  opener/separator/closer — one cell of whatever layout applies.
- **Activation**: a `//` line is a directive **iff it parses cleanly** —
  every command recognized with valid args, valid name — and, for
  separator/closer/bare forms, a group actually open. Anything else is
  literal prose, and keeps soft-wrapping into a preceding paragraph exactly
  as in plain markdown.
- An unknown or malformed command deactivates the whole line (strict, so
  typos are *seen* — and an older strike renders a newer document's opener
  as visible prose, never broken layout).
- Unterminated groups run to end-of-document; the closer is optional.
- Groups nest; separators and closers bind to the innermost open group. A
  `// end <name>` naming anything other than the innermost group is prose.
  Nested *layout commands* fall to the layout-level rule.

### Single-command directives — `/`

A `/command(args)` line — `/` immediately followed by exactly one command
token and nothing else — applies its command to the **very next content
element**, as if that one element were a nameless one-section group.
(`docs/design/002-single-command.md`.)

- `//` is checked first; a second `/` always means the group family.
- **Activation**: the command must parse cleanly *and* a content element
  must follow (blank lines skipped). At end-of-document, or with another
  directive next, the line is inert prose — so `/` lines never stack.
- The layout-level rule applies as if the wrapper were a group.

### Alias directives — `:` (reserved)

The `:` namespace is reserved for **alias definitions** — naming a command or
command-set for reuse, usable in-document and collected into shared `.sxh`
header files. Intended direction (2026-07-16): `:thin-grid grid(2)
skinny(80%)` would define `thin-grid`, and `// thin-grid` would then open a
group carrying both commands. **No `:` directive is currently defined** —
every `:` line is ordinary prose, and `.sxh` contents are inert. (The
namespace was originally earmarked for typography *settings* — the `:color`
directive and its `(name)` block prefix, removed 2026-07-14; the alias
direction supersedes that idea. Open for the eventual design: an alias name
in a `//` opener sits in the group-name position, so alias resolution and
group naming must be disambiguated. A `(name)` prefix remains plain prose.)

## Commands

A **command** is a `word(args)` token — parens required, so command keywords
can never collide with group names. One vocabulary serves group openers and
single-command directives. Most commands are **layout commands** (they make
their target a layout element and count under the layout-level rule);
`color` is the first **non-layout command** — it styles content without
creating a layout element and never counts under the rule.

| Command | Meaning |
| --- | --- |
| `grid(n)` | n columns; sections fill left-to-right and wrap. n ≥ 1. A section count ≠ n still renders, with a warning. |
| `skinny(N%)` | the element/group takes N% of the main body's width, centered. N is 1–100, `%` required. `skinny()` defaults to 75%. *(defaults provisional — `docs/design/003-skinny.md`)* |
| `center()` | text within the element/group is center-aligned, relative to the surrounding layout element. No arguments. (`docs/design/005-center.md`) |
| `color(role)` | text within the element/group takes the theme color role `accent`, `muted`, or `fg`. Non-layout: color-in-color nests, innermost wins. (`docs/design/006-color.md`) |

Commands combine (`// g grid(2) skinny(80%)` is a narrower grid). Malformed
arguments deactivate the whole line — `skinny(50)`, `grid(0)`, `center(5)`,
`color(red)`, `glow(5)` all leave their line as prose.

### Color roles and the inline color span

Strikedown never names concrete colors. A **color role** is a slot in the
renderer's theme — `accent` (the theme's signature color), `muted`
(secondary text), `fg` (body text, the reset) — and each renderer/theme
decides what a role looks like, so colored documents follow the reader's
theme (`docs/design/006-color.md`).

`color` is also the one command with an **inline** position: a **color
span** `[text].color(role)` colors a run of inline content mid-line. The
bracketed text is inline-parsed (bold, code, math inside all work); the
postfix must follow the `]` immediately and name a valid role, else the
whole thing is ordinary prose.

Color is deliberately restricted where interactions would be ambiguous:

- The link form wins the `[`: `[label](url).color(x)` is a link followed by
  literal prose (links can't be colored), and a link inside a span's
  brackets parses exactly as it would in plain markdown (no span forms).
- Spans don't nest: the earliest `].color(` closes the span.
- Elements that own a theme color — links, blockquotes, code — keep it
  inside colored groups and spans; `color` reaches only plain flowing text.

### The layout-level rule

The rule is **per command** (`docs/design/004-per-command-layout.md`): a
layout command on a group (or `/` line) whose ancestor group already carries
the *same* command is **ignored with a warning** — the group/wrapper still
forms, so document structure never depends on depth. Different commands nest
freely (a skinny element inside a grid cell is fine); the same command never
stacks, at any depth — no grids inside grids, no skinny inside skinny, even
with other layout in between. On an opener mixing commands, only the
colliding command is stripped; the others still apply. Plain named
containers never consume a level: a grid inside a command-less group is
fine.

## The markdown subset

A practical GFM subset. Gaps are tracked in CLAUDE.md's roadmap (setext
headings, HTML blocks, footnotes/reference links, front matter); GFM is the
spec for closing them.

- **ATX headings** `#`–`######`, each with an anchor id slugified from its
  text and deduplicated per document (`-2`, `-3`, …).
- **Paragraphs** — consecutive normal text lines join into one flowing text
  element (soft-wrap, joined with a space); a blank line separates.
- **Blockquotes** `>` — the same merging rule inside the quote:
  consecutive `>` lines flow into one paragraph; a bare `>` line breaks
  paragraphs within the quote; a plain line directly after a `>` line
  **lazily continues** the open quote paragraph. A blank line — or any line
  starting a new block form — ends the quote.
- **Lists** — unordered (`-`/`*`/`+`) and ordered (`1.`), nested by
  indentation (≥ 2 columns), `[ ]`/`[x]` task boxes. A plain line — indented
  or not — **lazily continues** the open item (the same rule as quotes).
  Blank lines between items do **not** end the list: after a blank, a marker
  that continues it (a sibling of the same orderedness, or a nested item)
  resumes; anything else ends it. Rendering stays tight regardless of blank
  lines (GFM's `<p>`-wrapped loose rendering is deliberately out of scope —
  item spacing is the renderer's concern). An ordered list starts at its
  first item's written number (GFM: later numbers are ignored).
- **Pipe tables** — header row + `|---|` separator, `:-:` alignment;
  body rows pad/truncate to the header width.
- **Fenced code** ```` ``` ```` with an info-string language; the body is
  verbatim, never inline-parsed.
- **Display math** `$$…$$` and **inline math** `$…$` — the TeX passes
  through raw (backends decide typesetting); never inline-parsed.
- **Horizontal rules** `---` / `***` / `___`.
- **Inlines**, in precedence order: backslash escape, `` `code` ``,
  `$math$`, `![image](src)`, `[link](url)`, `[text].color(role)` color
  spans (superset — see "Color roles"), `<autolink>` and bare `http(s)://`
  URLs, `***bold-italic***` / `**bold**` / `*italic*`, `~~strikethrough~~`.
- **Cross-document links** — a *relative* link target ending in `.md`/`.sx`
  (optional `#fragment`) addresses a sibling document by file path, resolved
  from the linking document's own directory (`design/spec.md`,
  `../notes.sx#anchor`). Renderers that know the site resolve it to the
  target's route (extension dropped; a `main.*` target lands on its folder's
  own page); the same source stays a working file link on GitHub or any
  plain-markdown viewer. Absolute URLs, `/site-absolute` paths, and non-doc
  targets pass through verbatim.

## Canonical examples

Two lists side by side:

```
// two_lists grid(2)

1. a
2. b

// --

1. c
2. d

// end two_lists
```

One narrow paragraph:

```
/skinny(50%)

this paragraph takes half the body width
```

A narrow element inside a grid cell (different commands nest; a second
`grid` here would be ignored with a warning):

```
// outer grid(2)

/skinny(50%)
a narrow paragraph in the left cell

// --

the right cell

// end outer
```

A muted aside, and one accent word (block and inline color):

```
// aside color(muted)

secondary text; the [key point].color(accent) still pops

// end aside
```

A merged, lazily-continued quote (two paragraphs):

```
> quote line one
> quote line two
>
> second paragraph
lazy continuation line
```

Degradation — every line below is an ordinary paragraph:

```
// just a comment here      (bare words after the name → unknown → prose)
// box glow(5)              (unknown command → whole line deactivates)
// --                       (no group open)
//foo                       (no space after the marker)
/usr/bin/env foo            (not a command: no parens)
/skinny(50%) extra          (trailing text)
/color(red)                 (unknown color role)
[x].color(bright)           (inline near-miss: unknown role → literal text)
[z](https://z.dev).color(muted)   (the link wins its `[`; postfix is prose)
:thin-grid grid(2) skinny(80%)   (reserved namespace, nothing defined yet)
(name)# not a heading       (retired prefix: plain prose)
```
