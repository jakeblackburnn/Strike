# 002 — Single-command directives (`/command()` lines)

**Status: shipped** (syntax and binding dictated by Jack, 2026-07-14;
mechanics drafted by AI the same day and implemented with them — see the
provisional flags in `003-skinny.md` for the parts still awaiting review).

## Problem

Group directives (`//`, note 001) arrange *runs* of content, but applying one
command to one element costs three lines of ceremony (opener, element,
closer). The common case — "make just this next thing narrow" — wants a
one-line form.

## Terminology

- **Single-command directive** — a block-position line `/command(args)`: a
  `/` immediately followed by exactly one command token and nothing else.
  It applies its command to the **very next content element**.
- Commands are the same vocabulary as group openers (`word(args)`, parens
  required — `grid(2)`, `skinny(60%)`); one grammar, one `parseCommand`.

## Decision (grammar and semantics)

| Line | Meaning |
| --- | --- |
| `/command(args)` | apply the command to the very next content element |

- **Marker**: `/` followed by anything but another `/` — `//` always belongs
  to the group family (checked first). No space between `/` and the command.
- **One command per line**, nothing after it. `/skinny(50%) extra` is prose.
- **Activation**: the line is a directive **iff** the command parses cleanly
  *and* there is a content element to bind to. With EOF or another directive
  (a `/` line, a live `//` line, a `:` directive) next, the line is inert
  prose — the same context-liveness rule that keeps separators/closers
  outside a group inert. Consequently `/` lines never stack.
- **Tree shape**: the directive produces the same `Group` node as `//`
  groups — nameless, one section holding the one element — so the emitter,
  the layout-level rule, and future backends need no second path. It is
  exactly "an anonymous single-element layout element."
- **Layout-level rule** applies (see `docs/STRIKEDOWN.md`): inside a group
  that already carries a layout command, the wrapper still forms but the
  command is ignored with a warning.
- `/grid(n)` is grammatical but pointless on one element: it applies and
  warns (`single command: grid(n) but 1 element`), matching the grid
  section-count-mismatch precedent.

### Accepted quirk: paragraph interruption is context-free

A cleanly parsing `/command()` line interrupts a paragraph via `isBlockStart`
without checking what follows it. So a valid command line whose *follower*
makes it inert (EOF/directive next) becomes its own one-line paragraph
instead of soft-wrapping into the previous one. Genuinely-prose slash lines
(`/usr/bin/env`) never interrupt — they aren't clean commands. Accepted:
the alternative (two-line lookahead inside every interrupt check) complicates
four call sites for a case that is already an authoring error.

## Degradation analysis

`parseCommand`'s strictness is the whole story: the line is prose unless it
is `/` + one recognized `word(args)` with valid args. Paths (`/usr/bin/env` —
no trailing paren), spaced forms (`/skinny (50%)`), unknown words
(`/glow(5)`), and trailing text all fail cleanly. Corpus check at decision
time: zero block-position `/word(` lines in `strikedown/`.

## Canonical examples

```
/skinny(50%)

this paragraph renders at half the body width
```

→ `<div class="sx-group" style="width:50%;margin-inline:auto">…one section,
one paragraph…</div>`

Degradations — all ordinary paragraphs:

```
/usr/bin/env foo        (not a command: no parens)
/skinny(50%) extra      (trailing text)
/skinny(50%)            (at EOF: nothing to bind to)
```

## Future direction

- Every new command (color, spacing, alignment) works here automatically —
  the form is command-agnostic by construction.
- If stacking is ever wanted (`/a() /b()` or consecutive `/` lines), it is a
  new decision; today's grammar deliberately rejects both.
