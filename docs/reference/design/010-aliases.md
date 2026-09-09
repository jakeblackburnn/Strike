# 010 — Alias directives (`:name command()*`)

**Status: shipped** (2026-09-01; decision dictated by Jack the same day).

## Problem

Layout vocabulary repeats: a document (or a whole project) that uses
`grid(2) skinny(80%)` on every figure pair wants to say that *once* and name
it. The `:` directive family is reserved for exactly this (the namespace's
settings-language past was reverted; note 006 records the redirect), and the
`.sxh` header plumbing — `strike.yaml`'s `header:`, `sheet.zig`'s loader,
the dormant parser arm — is wired and waiting. This note collects the design
space so the eventual decision has real alternatives; nothing here is
implemented.

## Terminology

- **Alias** — a name bound to a command list; using it applies those
  commands as if written in place.
- **Sheet** — the bundle of alias definitions in effect for a document:
  site header ∪ project header ∪ in-document lines (`sheet.Sheet`, today an
  empty shell).

## Candidates

### A — bare definition, bare use (the 2026-07-16 sketch)

```
:thin-grid grid(2) skinny(80%)

// thin-grid

a

// --

b

// end thin-grid
```

`:name command()+` defines; an alias name used where a command vocabulary
applies expands to its commands. In a `//` opener the bare first token today
lands in the *group-name* position — under A, a defined alias in that
position both names the group and applies its commands (`// end thin-grid`
still closes it). Undefined names keep meaning plain group names, so
nothing breaks; but a definition appearing later can silently change an
existing document's group from plain container to layout element — the
collision is the candidate's cost.

### B — marked use: aliases look like commands

```
:thin-grid grid(2) skinny(80%)

// figs thin-grid()
```

Use-side, an alias is written with parens, entering through `parseCommand`'s
lookup path like any command (a name-vs-command collision is impossible —
parens already separate the vocabularies). The group name stays a separate,
optional token: `// figs thin-grid()` is a group named `figs` carrying the
alias's commands. Slightly noisier; completely unambiguous, and `/thin-grid()`
single-command lines come free with zero extra grammar.

### C — definitions only in headers

Same use-side story as A or B, but `:` lines are only meaningful inside
`.sxh` files; in-document `:` lines stay prose forever. Documents stay pure
content; the cost is that a single self-contained `.sx` file can't name its
own vocabulary, which cuts against strikedown's plain-text-first posture.

## Semantics to pin (whichever candidate wins)

- **Expansion is one level.** An alias names commands, never other aliases —
  no recursion, no ordering puzzles inside the sheet.
- **Expansion happens before the layout-level rule.** The opener's effective
  attrs are computed (alias → commands → `applyCommand`), *then*
  `stripNestedLayout`/`enterLayout` run — nesting behaves exactly as if the
  commands were written out longhand.
- **Definition order.** The parser is single-pass, so an in-document
  definition must precede its first use (a use before the definition is a
  plain name/prose — the standard degradation). Header sheets are parsed
  before the document, so header aliases are always in scope.
- **Layering.** `Sheet.concat` semantics: later definition of the same name
  wins — site header, then project header, then in-document, so documents
  can locally override a project vocabulary.
- **Duplicate commands in one expansion** (alias carries `skinny(80%)`, the
  opener adds `skinny(50%)`): last-written wins via `applyCommand`, same as
  writing two commands on one opener today; no new rule.
- **Data shape.** `Sheet` grows a name → `Attrs` map (resolve commands at
  definition time — a bad definition line degrades to prose right there, and
  uses just merge a precomputed `Attrs`). The alternative, name → command
  token list resolved at use, only matters if resolution ever becomes
  context-dependent; nothing needs that.
- **Name validity** is `sheet.isAliasName` (`[A-Za-z0-9_-]+`), already the
  group-name rule. Command words (`grid`, `skinny`, …) should be reserved
  against aliasing to keep B's lookup unambiguous.

## Degradation analysis (mandatory)

`:` lines are ordinary prose today (the dormant `sheet.parseLine` arm
consumes nothing). When definitions activate: a `:name command()+` line that
parses cleanly is consumed as a directive (emits nothing); anything else —
`:only-a-name`, `:x grid(0)`, `: leading space` — stays prose, the
parses-cleanly rule. Use-side degradation differs by candidate: A changes
the meaning of existing *bare names* when a definition exists (the recorded
cost); B activates only `name()` tokens that are currently deactivating
unknown commands — documents that render today keep rendering identically.
Corpus check (2026-07-20): zero `^:` directive-shaped lines in
`strikedown/`.

## Decision

**B — marked use.** A `name()` use looks exactly like a command, entering
through the same lookup `parseCommand` already offers — no name/alias
collision is possible (parens separate the vocabularies), and `/thin-grid()`
single-command lines come free with zero extra grammar, exactly as
predicted. Every semantic pinned above shipped as written: one-level
expansion, expansion before the layout-level rule, single-pass definition
order (a use before its definition is a plain name/prose), `Sheet.concat`
layering (site header, then project header, then in-document — later wins),
last-written-wins on a duplicate command inside one expansion, resolve at
definition time into `Attrs` (a bad definition degrades right there, a use
just merges the precomputed snapshot — `command.mergeAttrs`), and command
words reserved against aliasing (`command.isCommandWord`).

One addition beyond the draft: `caption`'s backward-attach restriction
(`/cmd()` can't bind it — see note 018) applies uniformly to an alias that
happens to bundle `caption()`, not just the literal command — the check is on
the resolved `Attrs.caption_pos`, not on which spelling produced it.

Implementation: `sheet.zig` (`Sheet`, `Directive`, `parseLine`, `concat`);
`strikedown/command.zig` (`CommandTokenizer`, `mergeAttrs`, `isCommandWord`,
shared by both the alias-definition parser and the `//`-opener parser);
`strikedown.zig`'s `Parser.resolveCommandToken`/`resolveSingleCommandLine`/
`lookupAlias` (the one lookup path both the group-opener and `/cmd()`
directive parsers now share).

## Canonical examples

```
:thin-grid grid(2) skinny(80%)

// figs thin-grid()

a

// --

b

// end figs
```

→ the group renders exactly as `// figs grid(2) skinny(80%)` would. The same
alias also works bare (`// thin-grid()`, no separate group name) and as a
single-command directive (`/thin-grid()`).

Degradation: `:thin-grid grid(2) skinny(80%)` in a document rendered by an
older strike (or before its own definition line, in a single-pass parse) is
a visible prose line (never broken layout); `:note` alone (no commands)
stays prose everywhere, as does any command word used as a name (`:grid
grid(2)` — reserved).

## Future direction

- Aliases naming *color* sets (`:warn color(accent)`) restore the old named-
  color ergonomics over roles (note 006).
- Sheet → CSS compilation (roadmap): once aliases exist, an alias could emit
  a class + one stylesheet rule instead of repeated inline styles.
- Element-type-specific commands (`// ###.color(accent)`, MODEL.md's future
  note) would want aliases usable in selector position too — worth keeping
  in view when choosing A vs B.
