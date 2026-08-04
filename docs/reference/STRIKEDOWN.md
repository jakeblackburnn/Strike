# Strikedown — the language

The spec of record for strikedown (`.sx`), a typography-first superset of
markdown: every form and what it means. `docs/reference/design/NNN-*.md`
records how each decision was reached (history), and this file is what wins
when they disagree. Everything here is implementation-independent — each
sentence must stay true for every backend (HTML today, PDF planned), so nothing
names tags, CSS, or files.

For worked examples, read the `docs/example/` project, where every form below
is a rendered page you can open beside its source.

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
  the top-level layout element**. Layout elements nest, under the constraint
  set out in "The layout-level rule" below.
- **Directive** — a line addressed to the renderer rather than the reader.
  Directives emit nothing themselves; they configure, bracket, or create
  the above.

**Groups** sit between the taxa: a group (`//` lines, below) is a *named
container* bracketing a run of content elements into sections. What a group
*is* depends on what it carries:

- no commands — a **plain container**. It creates no layout element and nests
  freely.
- only non-layout commands (`color`, `indent`) — a **styled container**. It
  still creates no layout element, and still nests freely; it just changes how
  its contents read.
- any layout command — a **layout element**, and the layout-level rule applies
  to it.

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
- **Activation** has two halves, and a line needs both. It must **parse
  cleanly** — every command recognized with valid args, a valid name — *and*,
  for separator/closer/bare forms, a group must actually be open. `// --`
  parses perfectly and is still prose where nothing is open to separate.
  Anything that fails either half is literal prose.
- An unknown or malformed command deactivates the whole line (strict, so
  typos are *seen* — and an older strike renders a newer document's opener
  as visible prose, never broken layout).
- Deactivated lines are prose, but a line that parses cleanly and fails only
  the *context* half still breaks a preceding paragraph rather than
  soft-wrapping into it. A deliberate divergence: the alternative is deciding
  a line's block-ness from something arbitrarily far ahead of it.
- Unterminated groups run to end-of-document; the closer is optional.
- Groups nest; separators and closers bind to the innermost open group. A
  `// end <name>` naming anything other than the innermost group is prose.
  Nested *layout commands* fall to the layout-level rule.

### Single-command directives — `/`

A `/command(args)` line — `/` immediately followed by exactly one command
token and nothing else — applies its command to the **very next content
element**, as if that one element were a nameless one-section group.
(`docs/reference/design/002-single-command.md`.)

- `//` is checked first; a second `/` always means the group family.
- **Activation**: the command must parse cleanly *and* a content element
  must follow (blank lines skipped). At end-of-document, or with a live
  `//`/`:` directive next, the line is inert prose.
- **Chaining**: consecutive `/command()` lines apply to the same next
  content element, nesting innermost-last — `/skinny() /color(accent) text`
  is the nested-group form `// skinny()` → `// color(accent)` → text without
  the ceremony. A chain that never reaches a content element (EOF or a
  `//`/`:` directive at its end) reverts entirely to prose.
- The layout-level rule applies as if the wrapper were a group — including
  across a chain, so `/skinny() /skinny() text` strips and warns on the
  inner one exactly as two nested `// skinny()` groups would.

### Alias directives — `:` (reserved)

The `:` namespace is reserved for **alias definitions** — naming a command or
command-set for reuse, in-document and in shared `.sxh` header files
(`docs/reference/design/010-aliases.md`). **Nothing is defined yet**: every `:`
line is ordinary prose and `.sxh` contents are inert.

## Commands

A **command** is a `word(args)` token — parens required, so command keywords
can never collide with group names. One vocabulary serves group openers and
single-command directives. Most commands are **layout commands** (they make
their target a layout element and count under the layout-level rule); `color`
and `indent` are **non-layout** — they style content without creating a layout
element, so they nest freely and inner wins.

| Command | Meaning |
| --- | --- |
| `grid(n)` | n columns; sections fill left-to-right and wrap. n ≥ 1. A section count ≠ n still renders, with a warning. |
| `skinny(N%)` | the element/group takes N% of the main body's width, centered. N is 1–100, `%` required. `skinny()` defaults to 75%. *(defaults provisional — `docs/reference/design/003-skinny.md`)* |
| `wide(N%)` | the mirror of `skinny`: the element/group takes N% of the main body's width, centered, bleeding evenly into both margins. N is 101–200, `%` required. `wide()` defaults to 125%. (`docs/reference/design/012-wide.md`) |
| `center()` | text within the element/group is center-aligned, relative to the surrounding layout element. No arguments. (`docs/reference/design/005-center.md`) |
| `color(role)` | text within the element/group takes the theme color role `accent`, `muted`, or `fg`. Non-layout: color-in-color nests, innermost wins. (`docs/reference/design/006-color.md`) |
| `collapse()` / `collapse(open)` | the group folds behind its leader, closed (or open) on arrival. See "Collapsible groups". (`docs/reference/design/007-collapse.md`) |
| `indent(n)` / `indent()` | a first-line typographic tab indent, n steps (bare form is one). Non-layout: nesting overrides, innermost wins. See "Indentation". (`docs/reference/design/011-indent.md`, `015-paragraph-indent.md`) |
| `citations()` | the group's numbered list is the document's reference list: entries become anchor targets and `[text].cite(refs)` marks bind to them. One per document. No arguments. See "Citations". (`docs/reference/design/016-citations.md`) |

Commands combine (`// g grid(2) skinny(80%)` is a narrower grid). Malformed
arguments deactivate the whole line — `skinny(50)`, `wide(100%)`, `grid(0)`,
`center(5)`, `color(red)`, `collapse(true)`, `indent(x)`, `citations(2)`,
`glow(5)` all leave their line as prose. Numeric arguments are read as plain
decimal integers; write them plainly, and treat anything a stricter reading
would reject (`grid(+2)`, `skinny(5_0%)`) as unspecified rather than as
syntax.

`skinny` and `wide` are one width control with two names: both set the
element's width as a percentage of the body column, and their ranges meet at
100%. They combine with everything else but not usefully with each other —
written on the same opener, the last one wins.

A command means one thing, but content elements are not alike, and some of
them realize that meaning differently (a list's `indent` moves its markers
too — see "Indentation"). `docs/reference/design/013-command-realization.md` tracks
which of those cells are decided; most are still open.

### Collapsible groups

A group carrying `collapse()` folds away behind its **leader** until the
reader opens it; `collapse(open)` arrives already open. The leader is the
first content element of the group's **first section** — it never folds, it
always carries an open/close indicator, and the whole element is the control.
A group with fewer than two content elements has no leader to show, and one
whose first section is empty has none to find: either renders an anonymous
**empty bar** (indicator only) and folds everything beneath it. Other
commands on the same group apply to the *folded body*, not the leader.
Open/closed state belongs to the reading, not the document — nothing
persists. `collapse` is a layout command, so collapsible groups do not nest
(the layout-level rule strips the inner `collapse` with a warning).

Folding is a screen affordance, not document meaning: a renderer without
interactivity should show collapsible groups expanded.

### Indentation

`indent(n)` insets a block's own first line only — normal typographic tab
indentation, not a margin shift: the rest of a wrapped paragraph stays flush
against the body's left edge. On a group, the same command indents *each*
content element inside it (every paragraph, heading, etc. gets its own
first-line inset), not the group as a single shifted box.

A **list** is the exception, because its marker column is part of the element
and not part of its text: an indented list moves as a whole, markers and items
together, so a numbered list's numbers travel with their items rather than the
indent landing between them. A sublist inside an indented list is not shifted
again — its parent already moved. (`docs/reference/design/013-command-realization.md`,
which also tracks the still-open cases: quotes, code blocks, and tables
currently inset their contents rather than moving as boxes.)

**Leading whitespace** on a paragraph is sugar for one step of the same data
(`docs/reference/design/015-paragraph-indent.md`): a paragraph whose **first
line** begins with any whitespace carries `indent(1)`. The amount and kind are
deliberately not significant (the convention is two or four spaces); depth
beyond one step is `indent(n)`.

Two boundaries make that safe. It reaches **paragraphs only** — every other
block form, and all three directive families, ignore leading whitespace
exactly as they always have. And only a paragraph's *first* line is read, so
an indented line after a paragraph line is an ordinary soft-wrap continuation:
an indented paragraph must be preceded by a blank line.

Being non-layout, `indent` *scopes* rather than stacks — an inner `indent(n)`
overrides the inherited value for its own subtree, the same inner-wins cascade
`color` uses.

### Color roles and the inline color span

Strikedown never names concrete colors. A **color role** is a slot in the
renderer's theme — `accent` (the theme's signature color), `muted`
(secondary text), `fg` (body text, the reset) — and each renderer/theme
decides what a role looks like, so colored documents follow the reader's
theme (`docs/reference/design/006-color.md`).

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
- `[].color(role)` is degenerate rather than rejected — it parses and colors
  nothing. (The citation mark, which shares this grammar, rejects empty
  brackets outright; see "Citations".)
- `color` is for plain flowing text. Elements that own a theme color — links,
  blockquotes, code — should keep it inside colored regions. That is an
  obligation on a renderer's theme rather than something the document
  encodes, so how completely it holds is the renderer's business; strike's
  own reader honors it everywhere except citation marks, which take the
  surrounding color deliberately.

### Citations

A document cites in two halves (`docs/reference/design/016-citations.md`): inline
**marks** attach sources to the text making the claim, and one `citations()`
group declares where the sources live.

The **mark** is `[text].cite(refs)` — the same inline postfix grammar as the
color span, inheriting its mechanics: the bracketed text is inline-parsed,
the postfix must follow the `]` immediately, the link form wins the `[`,
spans don't nest, and any malformed part leaves the whole thing literal
prose. A citation is deliberately a **span, not a point**: it attaches the
source to the run of text making the claim, and that run is the reader's
affordance (renderers make the whole span the jump/preview target, with the
entry numbers set as a mark after it). Empty brackets (`[].cite(…)`) do not
parse — a bare point-citation form is reserved for a possible future note.

`refs` is one or more comma-separated references. Each is either a **number**
(all digits — the 1-based position of an entry) or a **key** (letters,
digits, `-`, `_`, at least one letter). The two shapes are disjoint by
grammar, so a key can never be mistaken for a position. `[both].cite(1, k)`
cites two sources with one mark.

The **bibliography** is a group carrying `citations()` — a structural
command, like `collapse`: it shapes what renderers emit rather than styling
it. The group must contain a **numbered list** — specifically the first one
sitting directly in the group, taking its sections in order; a list nested
inside a sub-group does not count, and a second list is ignored. Its items
are the entries, in the author's order. Entries are ordinary content — full
inline markup, written and ordered by the author; `citations()` does not
define a data format, it declares what an already-written list is. An entry
may open with a leading `[key]` (the same key shape), which binds that key to
the entry and is lifted from the rendered text; an all-digit or otherwise
non-key bracket stays literal prose. Key lifting happens only inside the
declared citations group — nowhere else does a leading bracket mean anything
new.

Entries are numbered **1..n by position**, whatever numbers the list is
written with. A list that starts at 1 — the overwhelmingly normal case — has
nothing to think about. A list that starts anywhere else warns, because the
numbers the reader sees would otherwise disagree with the numbers marks bind
to.

One citations group per document: later ones keep their content but drop the
command with a warning (and citations-in-citations strips under the
layout-level rule). A group carrying the command with no numbered list to
find keeps its content, warns, and renders as an ordinary group. Marks
anywhere in the document — before or after the group — bind to it. A number
out of range, an unknown key, a duplicate key (the first entry wins), or a
mark with no citations group at all warns and renders that reference inert.

Renderers set the group as a bibliography: entries become anchor targets,
marks link to them, entries link back to every citing mark.

### The layout-level rule

The rule is **per command** (`docs/reference/design/004-per-command-layout.md`): a
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

A practical GFM subset. These standard-markdown forms are not implemented yet:
**setext headings**, **HTML blocks**, **footnotes and reference links**,
**front matter**, **`_underscore_` emphasis**, **hard line breaks** (trailing
two spaces or `\`), **`~~~` fences**, **`1)` ordered markers**, and **HTML
entities**. Each is inert text today. They need no design note when they land:
GFM is already their spec, so closing a gap means implementing to it and
recording the result here.

- **ATX headings** `#`–`######`, each with an anchor id slugified from its
  text and deduplicated per document (`-2`, `-3`, …). Slugs lowercase ASCII,
  swap runs of non-alphanumerics for `-`, and pass other bytes through as
  written; a heading that slugifies to nothing gets `section`.
- **Paragraphs** — consecutive normal text lines join into one flowing text
  element (soft-wrap, joined with a space); a blank line separates.
- **Blockquotes** `>` — the same merging rule inside the quote:
  consecutive `>` lines flow into one paragraph; a bare `>` line breaks
  paragraphs within the quote; a plain line directly after a `>` line
  **lazily continues** the open quote paragraph. A blank line — or any line
  starting a new block form — ends the quote. A quote holds **flowing
  paragraphs only**: a list, heading, fence, or nested `>` inside a quote is
  literal text in the quote's paragraph, not a nested block.
- **Alerts** — a blockquote whose *first* content is `[!TYPE]` becomes a
  callout titled by its type: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`,
  `CAUTION` (GFM's five) plus `TODO`, `EXAMPLE`, `QUESTION` (superset),
  matched case-insensitively. Text after the marker on its line starts the
  first paragraph (superset — GFM wants the marker alone); everything else
  follows normal blockquote rules. An unknown type is no marker: the quote
  stays plain and the text literal. (`docs/reference/design/009-alerts.md`)
- **Lists** — unordered (`-`/`*`/`+`) and ordered (`1.`), nested by
  indentation (≥ 2 columns, a tab counting as 4), `[ ]`/`[x]` task boxes
  (`[X]` too). A plain line — indented
  or not — **lazily continues** the open item (the same rule as quotes).
  A **raw list** (superset) uses the `. ` marker: unordered, rendered with
  no visible marker; otherwise a full list (nesting, task boxes, the rules
  below). Marker kinds never mix at one level — a `. ` item beside a `- `
  item starts a sibling list, the same split ordered vs unordered makes.
  (`docs/reference/design/008-raw-lists.md`)
  Blank lines between items do **not** end the list: after a blank, a marker
  that continues it (a sibling of the same orderedness, or a nested item)
  resumes; anything else ends it. Rendering stays tight regardless of blank
  lines (GFM's `<p>`-wrapped loose rendering is deliberately out of scope —
  item spacing is the renderer's concern). An ordered list starts at its
  first item's written number (GFM: later numbers are ignored).
- **Pipe tables** — header row + `|---|` separator, `:-:` alignment;
  body rows pad/truncate to the header width. `\|` puts a literal pipe in a
  cell; an unescaped one splits, including inside a code span.
- **Fenced code** ```` ``` ```` with an info-string language (the first token;
  the rest is ignored); the body is verbatim, never inline-parsed. An
  unterminated fence runs to end-of-document, as does an unterminated `$$`.
- **Display math** `$$…$$` and **inline math** `$…$` — the TeX passes
  through raw (backends decide typesetting); never inline-parsed. An inline
  span requires all of: the opening `$` followed by a non-whitespace
  character, the closing `$` preceded by one and *not* followed by a digit,
  and a non-empty body. So `costs $5 and $10` and `$HOME and $PATH` are prose,
  while `$x^2$` is math.
- **Horizontal rules** `---` / `***` / `___` — three or more of one character,
  unbroken. GFM's space-separated `- - -` is not a rule here.
- **Inlines**, in precedence order: backslash escape, `` `code` ``,
  `$math$`, `![image](src)`, `[link](url)`, `[text].color(role)` color
  spans (superset — see "Color roles"), `[text].cite(refs)` citation marks
  (superset — see "Citations"), `<autolink>` and bare `http(s)://`
  URLs, `***bold-italic***` / `**bold**` / `*italic*`, `~~strikethrough~~`.
  Autolinks and bare URLs are `http`/`https` only. A bare URL must start the
  text or follow a space or `(`, and trailing `.,;:!?)` stays outside the
  link, so a sentence-final URL reads correctly. An image's alt text is
  literal, never inline-parsed.
  Inline syntax reads the *joined* text of a flowing element, not one source
  line: a span may open on one soft-wrapped line and close on a later one
  (`*asdf` then `asdf*` is one italic run), in paragraphs, quote paragraphs
  and list items alike.
- **Flanking** — emphasis and strikethrough delimiters are context-sensitive,
  by CommonMark's left/right-flanking rule: a delimiter run may open a span
  only if it isn't followed by whitespace, and close one only if it isn't
  preceded by whitespace (with punctuation on the far side relaxing each
  clause). So `a * b * c` and `5 * 4 * 3` are literal asterisks, while
  `**"quoted"**` and `intra*word*em` still emphasize. A candidate closer that
  can't close is skipped rather than fatal: `*a * b*` is one emphasis
  containing an asterisk.
- **Cross-document links** — a *relative* link target ending in `.md`/`.sx`
  (with an optional `#fragment` or `?query`, carried through untouched)
  addresses a sibling document by file path, resolved
  from the linking document's own directory (`design/spec.md`,
  `../notes.sx#anchor`). Renderers that know the site resolve it to the
  target's route (extension dropped; a `main.*` target lands on its folder's
  own page); the same source stays a working file link on GitHub or any
  plain-markdown viewer. Absolute URLs, `/site-absolute` paths, and non-doc
  targets pass through verbatim.

## Diagnostics

Nothing below is an error: every one of these renders, and the document keeps
its structure. A warning means the renderer did something other than what the
line literally asked for, and says so — layout mistakes are visible, not fatal.

| Warning | Cause |
| --- | --- |
| `group '<name>': grid(n) but m section(s)` | a `grid(n)` group with the wrong number of sections; all sections still render |
| `single command: grid(n) but 1 element` | `/grid(n)` on a single content element |
| `group '<name>': <cmd> ignored (already inside a <cmd>)` | the layout-level rule; the group still forms |
| `single command: <cmd> ignored (already inside a <cmd>)` | the same rule on a `/cmd()` line or chain |
| `group '<name>': citations ignored (the document already has a citations group)` | a second `citations()` group; it renders as an ordinary group |
| `group '<name>': citations ignored (no numbered list in the group)` | `citations()` with no entry list to declare |
| `citations: the entry list starts at n; entries still bind as 1..n` | a bibliography written with numbers that don't start at 1 |
| `citations: duplicate key [k] (the first entry wins)` | two entries claiming one key |
| `cite(k): unknown key` / `cite(n): only m entries` | a mark referencing an entry that isn't there; that reference renders inert |
| `n citation mark(s) but no citations group` | marks with nothing to bind to, reported once |

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

A cited claim and its bibliography — the span binds to entry 1 by position
and the key `lamport86` names entry 2; the `[lamport86]` prefix is lifted
from the rendered entry:

```
[Line-breaking is best solved as a dynamic program].cite(1) — a result
that predates the system it was written for, as [Lamport later
noted].cite(lamport86).

// citations()

1. D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
2. [lamport86] L. Lamport, *LaTeX: A Document Preparation System*, 1986.

//
```

Every other form has a live example in the `docs/example/` project rather than
a sample here, so the examples are rendered documents you can read next to
their source.

Degradation — every line below is an ordinary paragraph:

```
// just a comment here      (bare words after the name → unknown → prose)
// box glow(5)              (unknown command → whole line deactivates)
// --                       (parses fine; no group open)
// end other                (names something other than the innermost group)
//foo                       (no space after the marker)
/usr/bin/env foo            (not a command: no parens)
/skinny(50%) extra          (trailing text)
/color(red)                 (unknown color role)
/collapse(true)             (unknown collapse argument)
/indent(x)                  (unknown indent argument)
[x].color(bright)           (inline near-miss: unknown role → literal text)
[z](https://z.dev).color(muted)   (the link wins its `[`; postfix is prose)
[].cite(1)                  (empty brackets: not a citation mark)
:thin-grid grid(2) skinny(80%)   (reserved namespace, nothing defined yet)
(name)# not a heading       (retired prefix: plain prose)
.item                       (no space after the dot: not a raw-list marker)
a * b * c                   (space-flanked delimiters: literal asterisks)
5 * 4 * 3                   (same — multiplication, not emphasis)
costs $5 and $10            (a digit after the closing candidate: not math)
$HOME and $PATH             (space before the closing candidate: not math)
```

And two quote-shaped near-misses: `> [!IDEA] hm` is a plain blockquote with
literal text (unknown type), as is a `[!NOTE]` appearing anywhere but the
quote's first content.
