# The internal model

The model of record for how a strikedown document exists inside strike: the
document tree, the pipeline that builds and consumes it, and the exact mapping
between the spec's vocabulary (`STRIKEDOWN.md`) and the code's types
(`src/strikedown.zig`). `STRIKEDOWN.md` says what a document *means*; this file
says what a document *is* once parsed — read it before writing a new backend
(the PDF renderer walks exactly what is described here) and before extending
the language.

Two rules govern the model:

- **The tree is data.** Layout and typography land as attributes on tree
  nodes; emitters read attributes and never special-case on content. There
  are no renderer interfaces, plugins, or registries — a new backend is a new
  file walking the same tree.
- **Parse is pure.** `strikedown.parse(arena, src, base_sheet) !Doc` does no
  I/O, prints nothing, and allocates only from the caller's arena (slices
  either point into `src` or into arena allocations — free the arena, free
  the doc; never free nodes piecemeal). Everything observable about parsing
  is in the returned `Doc`, including its diagnostics.

## The pipeline

Two stages, always:

```
source text ──parse──▶ Doc (tree + warnings) ──emit──▶ output
                        │
                        ├─ render_html.emit   (HTML fragment, today)
                        └─ render_pdf         (planned)
```

`parse` runs line-based: the source splits into lines (a trailing `\r` per
line is stripped), then a **block loop** classifies each non-blank line and
consumes one block at a time. Inside blocks, inline text runs through the
**inline chain** — one arm per form, tried in the spec's precedence order at
each position, left to right (precedence breaks ties at the *same* position;
an earlier opener wins over a later, higher-precedence one). Code and math
bodies are never inline-parsed.

Flowing text (a paragraph, a quote paragraph, a list item and its lazy
continuations) gathers its lines into one space-joined string *first* and
inline-parses that string **once** — inline syntax is a property of the joined
text, never of a single source line, so a span may open on one line and close
on a later one (`*asdf` / `asdf*` is one emphasis). The joining helper is
`appendFlowLine`; for list items `flushFlow` ends the run.

Block classification has one structural rule worth naming — the
**`isBlockStart` companion rule**: every block form needs an arm in
`isBlockStart` (so a preceding paragraph doesn't swallow its first line as a
soft-wrap continuation), except forms that need context, which get companion
checks instead: pipe tables (`isTableStart`, two-line lookahead) and group
directives (`isGroupInterrupt`, needs the open-group count). The one shared
"does this line break a flowing text run" check is `interruptsFlow`, used by
the paragraph loop, quote lazy continuation, and list item continuation.

Directive lines are classified before content: a `:` line is offered to
`sheet.parseLine` (reserved namespace, recognizes nothing today — the arm is
dormant and self-reactivating), a `//` line to `parseGroupLine` (a directive
iff it parses cleanly, otherwise prose), a `/cmd()` line to
`parseSingleCommandLine` (desugars to a nameless one-section group around the
next content element).

After the block loop, `parse` runs one **whole-tree pass** —
`resolveCitations` (note 016), the first and so far only one: forms whose
meaning needs the whole document (a citation mark and its entry can sit at
opposite ends) resolve here, still inside `parse` (pure, arena-owned), so
every backend walks an already-resolved tree. The pass adopts the document's
one citations group (stripping the command from later siblings with a
warning — the layout-level rule covers nesting, this covers siblings), finds
its entry list (the first top-level numbered list in the group; none
degrades the command with a warning), lifts `[key]` prefixes off entries
(the language's one context-scoped form — implemented as tree rewriting
here, never as context threaded into line parsing), then numbers every mark
site in document order and resolves each ref to an entry position, recording
backlinks on the entries. Unresolved refs (unknown key, out of range, no
group) zero out with a warning and render inert.

Emitters walk `Doc.blocks` recursively (groups contain blocks). The HTML
backend is `render_html.emit(gpa, doc, opts)`; `render_html.render` is the
parse+print-warnings+emit convenience every caller uses. Nothing in the tree
is HTML-specific; where this file mentions HTML output it is describing one
backend's realization, not the model.

## The tree

Defined at the top of `src/strikedown.zig`. All names below are public types.

```
Doc
├── blocks: []Block
└── warnings: []const []const u8

Block
├── attrs: Attrs                 ← command-derived, default empty
└── kind: union(enum)
    ├── heading    (level, id, inlines)      ─┐
    ├── paragraph  ([]Inline)                 │
    ├── quote      (Quote: ?alert, paras)     │
    ├── list       (List: ordered/plain/start/items)  content elements
    ├── code       (lang, text)               │  ("text elements" in the spec)
    ├── table      (aligns, header, rows)     │
    ├── math       (raw TeX)                  │
    ├── rule                                 ─┘
    └── group      (Group: name, sections: [][]Block)   ← the container node

Attrs                            ← every command writes exactly one field
├── columns:    ?usize           ← grid(n)      (layout)
├── width_pct:  ?usize           ← skinny(N%) / wide(N%)  (layout)
│                                  one field, two commands: ≤ 100 is skinny,
│                                  > 100 is wide (the ranges are disjoint by
│                                  grammar, which is what tells them apart)
├── centered:   bool             ← center()     (layout)
├── text_color: ?TextColor       ← color(role)  (non-layout)
├── collapse:   ?Collapse        ← collapse()   (layout, structural)
├── citations:  bool             ← citations()  (layout, structural)
└── indent:     usize            ← indent(n), or one step from a whitespace-
                                   indented paragraph  (non-layout)

Inline: text · code · math · image · link · autolink ·
        strong · em · strong_em · strike · color_span(color, children) ·
        cite_span(CiteSpan: refs, site, preview, children)
```

Citation resolution lands as data in three places (all written by the
`resolveCitations` pass, all zero/empty until it runs): `CiteSpan.site` (the
mark's 1-based document-order index — its anchor identity) with each
`CiteRef.num` resolved to an entry position (0 = unresolved, renders inert)
and `CiteSpan.preview` (the cited entries as plain text, for hover
affordances); and on the entry list's items, `Item.cite_entry` (the item's
1-based entry number) and `Item.cite_sites` (the sites citing it — its
backlink targets). Keys are transient: lifted from entry text and consumed by
resolution, they never appear in the tree.

The load-bearing decision: **`Attrs` lives on every `Block`**, not on `Group`.
Groups are today the main *targeting mechanism* — the syntax that gets a
command applied somewhere — and `Group` itself holds pure structure (name +
sections). Two block kinds carry non-default attrs today: group blocks, and
any paragraph whose first line is whitespace-indented (`indent = 1`, note
015). But the slot is uniform: a future element-type-specific command
(`// ###.color(accent)`, still needing a design note for its selector syntax)
will write these same fields onto heading blocks directly, and no model change
will be needed — only the new targeting syntax.

Emission is uniform with one exception. Every emitter arm passes its block's
attrs through the shared style helper — *except display math*, which the HTML
backend emits as bare delimiters with no element to hang a style on, silently
dropping any attrs it carries. That is the `*open, blocked*` column in note
013's matrix, and it is a gap to close, not a rule.

Invariant: `attrs.columns` only ever appears on a group block, because `grid`
arranges *sections* and only groups have them. Backends may rely on this
without a guard.

Two content-element payloads carry a *variant* of their form rather than a
separate kind: `Quote.alert` (an `Alert` tag when the quote's first content
was a recognized `[!TYPE]` marker — note 009) and `List.plain` (a raw `.`
list — note 008). An alert is still a quote and a raw list is still a list;
backends branch on the flag for presentation, never for structure.

## Taxonomy ↔ types

The spec's element taxonomy maps onto the tree as follows. Note which terms
are *types* and which are *roles* — the distinction resolves every fuzzy edge.

| Spec term (`STRIKEDOWN.md`)  | In the tree                                       |
| ---------------------------- | ------------------------------------------------- |
| content element              | a `Block` whose kind is not `group`               |
| text element                 | same — all current content elements are text      |
| group                        | a `Block` with `kind == .group` (a `Group` node)  |
| **layout element**           | *a role, not a type*: a group whose `attrs` carry ≥ 1 **layout** command |
| styled container             | *a role*: a group whose attrs carry only non-layout commands (e.g. `color`) |
| plain container              | *a role*: a group with empty attrs                |
| section                      | one `[]Block` in `Group.sections`                 |
| command                      | `Command` (union: grid, skinny, wide, center, color, collapse, citations, indent) |
| directive (group / single-command / alias) | `GroupLine` / `parseSingleCommandLine` / `sheet` namespace — transient parse classifications; directives never appear in the tree |
| color role                   | `TextColor` (accent, muted, fg)                   |

The tree types above (`Doc`, `Block`, `Attrs`, `Inline`, `TextColor`, …) are public;
the parsing machinery named in the last two rows — `Command`, `GroupLine`,
`parseCommand`, `applyCommand`, `isLayout`, `resolveCitations`, `isBlockStart` — is
private to `strikedown.zig`. A second backend consumes the tree and never touches them;
the extension recipes below are for work *inside* the parser.

So "is a color-only group a layout element?" — no. Layout-element-ness is a
per-block *role* derived from attrs (`isLayout` classifies each command tag),
never a distinct node type. A single-command directive produces the same
`Group` node as a `//` opener: nameless, one section; it is a layout element
or styled container by exactly the same test. The main body of the document
(the top-level `[]Block`) is the implicit outermost layout element.

## Command realization (the HTML backend)

What each command *means*, and its argument grammar, is
`docs/reference/STRIKEDOWN.md`'s — this table is only what the first backend
does with it. Style declarations come from one place,
`render_html.writeStyleAttr`; structural commands shape elements instead.

| Command      | Layout? | HTML realization |
| ------------ | ------- | ---------------- |
| `grid(n)`    | yes     | CSS grid, fixed gap |
| `skinny(N%)` | yes     | `width:N%;margin-inline:auto` |
| `wide(N%)`   | yes     | `width:N%;margin-inline:calc((100% - N%) / 2)` |
| `center()`   | yes     | `text-align:center` |
| `color(role)`| no      | `color:var(--role)` |
| `collapse()` / `collapse(open)` | yes | `<details class="sx-group sx-collapse">`/`<summary>` + a body wrapper carrying the group's other attrs — element shape, not style |
| `indent(n)`  | no      | depends on the element type — see below |
| `citations()`| yes     | a `<section class="sx-group sx-citations">` wrapper; entry `<li>`s get `id` anchors + backlinks, marks become links + a `<sup>` — element shape, not style |

The leader a `collapse` group folds behind is the first block of its **first
section**, and only when the group holds ≥ 2 blocks in total; anything else
gets the anonymous empty bar.

Backend obligations, in spec terms:

- **Theme-role indirection**: `color` names a role, never a concrete color; a
  backend maps roles to its own palette. Keeping element-owned colors (links,
  quotes, code) intact inside colored regions is part of that mapping, not
  something the tree encodes — the emitter writes one `color` declaration on
  the wrapper and the backend's own stylesheet decides what survives it.
- **The layout-level rule** is enforced at *parse time*, per command: the
  parser keeps one open-group counter per command tag (`Parser.layout_depth`);
  a layout command whose counter is already > 0 is stripped from the opener
  with a warning naming it (the group still forms; other commands on the same
  opener survive). Non-layout commands never touch a counter and nest freely
  (inner wins by containment). Backends therefore never see an illegal
  nesting — the tree is already legal.
- **Grid mismatch** is also parse-time: `grid(n)` with a section count ≠ n
  warns but keeps all sections; the backend renders what's there (the HTML
  grid flows extras into new rows).
- **Attribute emission is uniform**: one helper renders a block's attrs; the
  declaration order (grid, width, center, color, indent) is owned there and
  locked by the render tests. New commands extend at the end.
- **Realization is per element type.** A command's *meaning* is one thing; how
  a given content element carries it out is another. Which pairs are decided
  and which are still open is one table:
  `docs/reference/design/013-command-realization.md`. The model-level
  consequence is that the emitter threads an enclosing group's indent down the
  walk, so a box-mode element can realize it itself instead of inheriting the
  wrong property. A second backend has no CSS inheritance to fall back on and
  must realize every pair explicitly.
- **Structural commands** (`isStructural`; `collapse` and `citations`) are
  realized as *element shape*, not style declarations — `Attrs.anyStyle`
  skips them, so the shared style helper never emits an empty attribute for
  them. The HTML backend folds a collapse group into a disclosure element
  whose summary is the leader and puts the group's styling attrs on the body
  wrapper (a grid style on the disclosure element would capture the summary
  as a grid item). A non-interactive backend (PDF) renders collapsible
  groups expanded — folding is a screen affordance, not document meaning.
  A citations group emits as a bibliography section; its resolution data
  (anchors, backlinks, mark sites) is already on the tree, so a backend only
  chooses shapes — the HTML backend makes the span a link with the entry
  numbers in a `<sup>` after it, and gives entries their anchors and
  backlinks in the entry `<li>`s wherever the list sits.

## Warnings

`Doc.warnings` is a flat list of human-readable strings in discovery order —
deliberately unstructured, because nothing branches on them: `parse` never
prints (purity), `render_html.render` prints each to stderr, and that is the
entire contract. If a structured consumer ever appears (an LSP, positioned
PDF diagnostics), the growth path is adding fields alongside the string at
the `Parser.warnings` append sites — not restructuring emitters.

## Extension recipes

The moves an implementation makes to extend the language, in model terms.
Language changes need a design note first (`docs/reference/DESIGN.md`), and every
canonical spec example becomes a parser test in `src/strikedown.zig` plus an
end-to-end test in `src/render_html.zig`.

- **A new inline form**: an `Inline` variant + its arm in the inline chain
  (mind precedence position) + its emitter arm.
- **A new block form**: a `Block.Kind` variant + its block-loop arm + the
  `isBlockStart` companion + its emitter arm.
- **A new command**: a `Command` variant, a `parseCommand` arm, an `Attrs`
  field written by an `applyCommand` arm, its arms in the exhaustive
  `isLayout`/`isStructural`/`hasCommand`/`clearCommand` switches (the
  compiler errors until they exist), and the emitter reading the field —
  the style helper for a styling command, the element shape for a
  structural one. The depth machinery, `//`-opener support, `/cmd()`
  support, and `Attrs.any` come free.
- **A form needing whole-document knowledge**: resolve it in a parse-end
  pass over the finished tree (`resolveCitations` is the precedent) — still
  inside `parse`, still pure, results landing as data on nodes. Backends
  never resolve; they only choose shapes.
- **Element-type-specific commands** (future): the attribute slot
  (`Block.attrs`) and uniform emission already exist; what remains is the
  targeting syntax — a selector grammar needs its design note, then a parser
  path that writes attrs onto matched content elements.
- **Alias directives** (future, `:` namespace): aliases resolve to command
  tokens and ride the existing `parseCommand`/`applyCommand` → `Attrs` path
  (`sheet.zig` holds the name → tokens map); they add vocabulary, never a
  second attribute pipeline.
