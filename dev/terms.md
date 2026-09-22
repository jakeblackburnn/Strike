# Terminology and design decisions

The vocabulary this codebase uses for itself, and the rules behind it — written once so
later changes can cite a rule instead of re-deriving it. Update this file when a term or
rule changes meaning; don't let the code and this file drift.

## Vocabulary

- **document / source** — the input text (`.md` today; `.sx` from `base_sx` on).
- **doc tree / `Doc`** — the parsed result (`src/doc.zig`): `blocks: []Block` plus
  `warnings`.
- **block** — one top-level (or group-nested, from `base_sx`) structural element:
  heading, paragraph, code. Also called a **content element** when contrasted with a
  future *layout element* (a group carrying a layout command — not in this base).
- **inline** — a span inside a block's text: plain text, code, strong, em.
- **the block loop** — `parse`'s line-by-line pass that classifies each line and
  consumes one block at a time (`src/parse.zig`).
- **flow / flow-joining** — gathering a paragraph's consecutive source lines into one
  space-joined string before inline-parsing it. Named because inline syntax is a
  property of the *joined* flowing text, not of a single source line.
- **the inline chain** — the one left-to-right pass over a flowed string that tries each
  inline form in precedence order at every position.
- **emitter / backend** — a `Doc` consumer that produces one output format.
  `emit_html.zig` is the only one today.

## Design decisions

**Two-stage rendering.** `parse` produces a tree; a separate emitter walks it
(`src/parse.zig` → `src/doc.zig` → `src/emit_html.zig`). HTML is the first backend; a
PDF backend, when it exists, is a sibling file walking the same tree. This is *why* the
tree exists — resist folding stages together even when the whole pipeline is three
files long, because the split is what a second backend needs later.

**The tree is data.** Presentation (when it exists) lands as fields on tree nodes;
emitters read those fields and never special-case behavior on document *content*. No
`IBlockRenderer`-style interfaces, no registries, no plugin layer for block or inline
kinds — a new form is a new union variant plus an arm in each stage, full stop.

**Parse is pure.** `parse(arena, src) !Doc` does no I/O and prints nothing. Every
observable fact about a parse — including diagnostics — is reachable through the
returned `Doc`. This is why `Doc.warnings` exists starting now, even though nothing
populates it yet: the field is part of the contract, and a caller that wants to print
warnings does it *after* calling `parse`, never inside it.

**Arena ownership.** A `Doc`'s slices point into the source string or into the arena
passed to `parse`. Free the arena, free the whole doc; nothing inside a `Doc` is ever
freed piecemeal.

**The `isBlockStart` companion rule.** Every block form needs a matching arm in
`isBlockStart` (`src/parse.zig`), or a paragraph that comes before it will swallow its
first line as a soft-wrap continuation instead of ending. A form whose start can't be
recognized from one line in isolation (a future multi-line or context-dependent form)
needs a purpose-built companion check instead of an `isBlockStart` arm — `base_sx`'s
group opener is the first example of this.

**Precedence in the inline chain.** Arms are tried in a fixed order at every position:
an earlier-appearing delimiter wins over a later, higher-precedence one; precedence only
breaks ties when two candidates start at the *same* position. Code spans are checked
first because their contents must never be reinterpreted as anything else.

**Diagnostics, not fatal errors.** Nothing a document can contain aborts a parse or
renders nothing — an unrecognized or ambiguous form either falls back to plain text or
(starting when `base_sx` adds groups) degrades to prose with a warning. `Doc.warnings`
is the channel for "the renderer did something other than what the source literally
asked for"; it is never used for "this document is invalid."

**One flavor, ever.** There is no `Flavor` enum and there will never be dialect
branching inside `parse.zig` or `emit_html.zig`. `.md` is the subset; a superset form
(from `base_sx` on) must be additive and inert until activated, so the same two files
handle both without an `if (is_sx)` anywhere. If a genuinely different dialect ever
exists, it is a different branch of this project, not a conditional in these files.

**Degradation / inert prose.** Every superset form must parse as ordinary text in a
document that doesn't deliberately invoke it. This can't be checked until there's a
superset form to check it against — `base_sx`'s group directive is the first one, and
its test (`// TODO: fix` staying a plain paragraph) is the load-bearing test of the
whole rule, not an incidental one.

**`Block` is a bare union at v0.0.1.** `src/doc.zig`'s `Block` is `union(enum) {
heading, paragraph, code }`, not `struct { kind, attrs }`. The `attrs`-alongside-`kind`
split (every block carrying shared presentation fields beside its structural payload)
is the anticipated next shape, expected the day a command or per-block style needs
attaching to more than one block kind — noted here so that refactor reads as planned,
not as an emergency.

## Vocabulary — added on `base_sx`

- **directive** — a renderer-addressed source line, distinct from ordinary content.
  `//` is the one directive family in this base (group open/close). A `/cmd()`
  single-command line and `:name` alias directive are backlog.
- **group** — a named container block (`doc.Group`: `name`, `sections`), opened by
  `// name`, closed by `// end name`. Carries no commands and no styling in this base —
  it groups content, nothing more.
- **section** — one `[]Block` slice inside a group's `sections`, split by a bare `===`
  line. A group with no `===` has exactly one section.
- **opener / closer** — the `// name` line that starts a group, and the `// end name`
  line that ends it.

## Design decisions — added on `base_sx`

**A `//` line is a directive iff it parses cleanly.** `// name` opens only when
everything after `//` is a single identifier token (letters, digits, `_`, `-`) and
nothing else; anything else — `// TODO: fix`, a stray phrase, extra words — is an
ordinary paragraph line. This is the degradation rule made concrete: the same source
byte sequence means nothing special until it unambiguously asks to. The corresponding
test (`// TODO: fix` renders as `<p>`) is the load-bearing test of the whole rule.

**A closer only closes the innermost open group.** `// end other` while `aside` is open
does not close `aside`, and does not error — it falls back to being an ordinary content
line, with a warning recorded on `Doc.warnings` (`group '<innermost>': mismatched closer
'// end <other>' treated as prose`). Nothing about a wrong closer is fatal; it just
means the renderer didn't do what that line literally seemed to ask.

**`===` only means something inside an open group.** At top level (no group open),
`===` is inert prose — the same "parses cleanly in context" rule extended to a
directive that has no meaning without a surrounding group.

**The nesting cap (64) degrades, it doesn't error.** A `// name` opener at or past
depth 64 is treated as if it weren't a valid opener at all — plain prose, with one
warning for the whole document ("nesting deeper than 64 levels…"), not per-line. In
practice this never fires in v0.0.1's samples; it exists because the recursive
`parseSection` needs a hard stop before untrusted input can blow the call stack, and a
stack-depth limit should behave like every other diagnostic in this codebase
(degrade-and-warn), not panic.

**The block loop is recursive, not iterative, in `base_sx`.** `parseSection` calls
itself once per group nesting level, returning why it stopped (`StopReason`: `eof` /
`split` / `closer`) so its caller — the group-opening arm — can tell "start the next
section" from "the group just closed" from "the document ended with this group still
open." This is the shape a tree-structured block form takes; a future layout command
or nested-list form extends the same pattern rather than inventing a new one.

**`interruptsFlow` replaces the plain `isBlockStart` check.** Once a block form's
start depends on context — here, "is a group currently open, and which one" — a
per-line-only `isBlockStart` check can't decide it alone. `interruptsFlow(line,
open_names)` is `base_sx`'s single shared answer to "does this line end a paragraph
that's being gathered," covering both the context-free forms (heading, fence) and the
context-dependent ones (opener, split, matching closer).

## Backlog (named, not built)

Everything below is a deliberate omission from v0.0.1, not an oversight. No design note
governs any of it yet.

**Markdown forms:** tables, lists (ordered/unordered/nested/task boxes), blockquotes
(incl. alerts), rules, display/inline math, images, links (incl. cross-document
resolution), autolinks and bare URLs, strikethrough, backslash escapes, CommonMark
flanking rules for emphasis, heading anchor ids/slugs, `1)` ordered markers, `~~~`
fences, setext headings, HTML blocks, footnotes/reference links, front matter, hard
line breaks.

**Superset (strikedown) forms beyond `base_sx`'s groups:** layout/styling commands
(`grid`, `skinny`/`wide`, `center`, `color`, `collapse`, `indent`, `caption`, `snug`),
the layout-level rule (a command nested under itself), single-command `/cmd()`
directives, alias directives (`:name`), citations (`.cite()` spans + `citations()`
group), `.sxh` header sheets.

**Toolkit:** HTTP server, `--watch`/live reload, site/project scanning, `strike.yaml`
config, static export (`strike build`), scaffolding (`strike init`), themes/seasons,
reader chrome (sidebar, nav, TOC), MathJax integration, doc-relative asset resolution.

**Process/infra:** design notes for language changes (revisit `docs/reference/DESIGN.md`
on `slopbox` for the process once there's a second superset form to decide).
