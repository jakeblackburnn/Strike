# 001 — Group directives (`//` lines)

**Status: shipped** (decision dictated by Jack, 2026-07-13; implemented and tested the
same day). Canonical examples merged into `docs/reference/STRIKEDOWN.md`.

**Superseded in part, 2026-07-14** (this note is history; the spec is truth):

- *Nesting*: groups still nest freely as containers and separators/closers still bind
  innermost, but **layout commands only apply one level below the main body** — a
  `grid`/`skinny` on a group whose ancestor already carries a layout command is ignored
  with a warning (the layout-level rule, `docs/reference/STRIKEDOWN.md`). **Revised 2026-07-16**:
  the rule is now *per command* — only the same command nested under itself is ignored
  (`004-per-command-layout.md`).
- *Terminology*: the spec refines this note's vocabulary — a **layout element** is now
  what a layout *command creates* (the main body being the top-level one); the
  renderer-addressed lines this note called "layout elements" are just **directives**.
  Groups without layout commands are named containers, not layout elements.

## Problem

Strikedown owns typography, but had no way to *arrange* content horizontally — e.g.
two lists side by side. This note introduces content **grouping**: a way to bracket a
run of blocks and apply layout commands to the group. It is the first layout feature
and deliberately establishes the grammar that future customization commands (block
color, width, …) will ride on.

## Terminology

Every block-position line is one of two kinds:

- **Content element** — a normal markdown/strikedown block (heading, list, paragraph…).
- **Layout element** — a line addressed to the renderer, not the reader. Two families:
  *typography directives* (`:` lines, `sheet.zig`) and **group directives** (`//`
  lines, this note).

Group-directive vocabulary:

- **Group directive** — any active `//` line. The marker is `//` followed by a space
  or end-of-line; `//foo` is prose.
- **Group name** — the first *bare* token of an opener (`two_lists`). Alias-safe
  charset (`sheet.isAliasName`: `[A-Za-z0-9_-]+`); `end` and `--` are reserved.
  Optional — an opener whose first token is a command opens a **nameless group**.
- **Command** — a `word(args)` token, parens required (`grid(2)`; later `color(red)`,
  `width(50%)`). Bare words are never commands, so a future command keyword can never
  collide with an existing document's group name.
- **Section** — the run of content elements between opener/separator/closer; one cell
  of the layout.

## Decision (grammar)

| Line | Meaning |
| --- | --- |
| `// <name> <command>*` | opener: named group |
| `// <command>+` | opener: nameless group (first token has parens) |
| `// --` | separator: next section of the innermost open group |
| `// end` / `// end <name>` | closer: closes innermost; a given name must match it |
| `//` (bare) | closer: same as `// end`, only meaningful while a group is open |

Semantics:

- **Activation**: a `//` line is a directive **iff it parses cleanly** — every command
  recognized with valid args, valid name — and, for separator/closer/bare forms, a
  group actually open. Anything else stays literal prose.
- **Unknown or malformed command deactivates the whole line** (strict, so typos are
  seen; an older strike renders a newer doc's opener as visible prose, never broken
  layout).
- **Unterminated groups run to EOF.** With the closer optional, named and nameless
  groups behave identically — the name is the only difference.
- **`grid(n)`** = n columns; sections fill left-to-right and wrap. A section count ≠ n
  still renders (wrapped) but emits a warning: `group 'g': grid(2) but 3 section(s)`.
- **Nesting** is allowed; `// --` / `// end` / `//` bind to the innermost open group.
  A `// end <name>` naming anything other than the innermost group is prose.
  *(Superseded 2026-07-14: nesting of containers stands, but nested layout commands
  are ignored with a warning — see the status block above.)*

## Canonical examples

Two lists side by side (the reference document, `strikedown/pchem/main.sx`):

```
// two_lists grid(2)

1. asdf
2. asdf

// --

1. asdf
2. asdf

// end two_lists
```

Nameless group, runs to EOF, no closer needed:

```
// grid(2)

left column

// --

right column
```

Degradation — all of these render as ordinary paragraphs:

```
// just a comment here      (bare words after the name → unknown → prose)
// box glow(5)              (unknown command → whole line deactivates)
// --                       (no group open)
// end
//foo                       (no space after the marker)
```

## Degradation analysis

The activation rule *is* the degradation story: a `//` line only changes meaning when
it parses cleanly, and clean parses are narrow (alias-safe name, parens-only commands
from the known set). Prose that happens to start with `//` — a comment, a path, a
slashed date — almost never parses cleanly, and when inert it also keeps soft-wrapping
into a preceding paragraph exactly as in plain markdown (the paragraph-interrupt check
only fires for live directive lines). Corpus check at decision time: zero `//` lines
in `strikedown/` outside the reference document.

The residual exposure: a block-position line like `// results` (exactly `//` + one
alias-safe word) *does* open a group — a container div wrapping the rest of the file,
which renders visually identically until layout commands are involved. Accepted.

## Future direction

- New commands are the vehicle for per-group customization: `color(red)`,
  `width(50%)`, gap/alignment controls. Each is a `Command` variant in
  `strikedown.zig`, an attribute on the `Group` tree node (or the shared `Block`
  attrs, e.g. color), and an emitter arm reading it — data, never emitter special
  cases.
- The PDF backend walks the same `Group` node; nothing in the grammar is HTML-shaped.
- Reader-side polish (responsive column collapse on narrow screens via the `sx-group`
  class) is toolkit work in `shell.zig`, out of scope for the language.
