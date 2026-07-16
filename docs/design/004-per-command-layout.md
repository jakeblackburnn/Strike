# 004 — Per-command layout nesting (revising the layout-level rule)

**Status: shipped** (decision dictated by Jack, 2026-07-16; implemented and tested the
same day). No new syntax — this note revises the *semantics* of the layout-level rule
(`001-groups.md`, `002-single-command.md`, `docs/STRIKEDOWN.md`).

## Problem

The original layout-level rule was global: layout goes exactly one level below the main
body, so a layout element can never contain another layout element. That forbids
compositions with an obvious meaning — a `skinny` paragraph inside a `grid` cell — for
the sake of blocking the genuinely ill-defined ones (a grid whose cell is another grid).
The global rule throws out the good with the bad.

## Terminology

- **Colliding command** — a layout command on a group (or `/` line) that some open
  ancestor group already carries.

## Candidates

No syntax is at stake; the candidates are enforcement semantics for nested layout
commands.

### A — global level (status quo)

One counter of open layout-carrying groups; any layout command while it is > 0 is
stripped with a warning.

```
// outer grid(2)

/skinny(50%)
this skinny is stripped — warning        ← the problem

// --
b
// end outer
```

Simple to state, but conflates "layout nests" with "a command stacks on itself".

### B — per-command level

One counter **per layout command** (keyed by the command, `grid`/`skinny` today). A
command whose counter is already > 0 anywhere up the open-group chain is stripped with a
warning naming it; commands with a zero counter apply normally — including others on the
same opener.

```
// outer grid(2)

/skinny(50%)
this skinny applies — no ancestor carries skinny

// --

// inner grid(2) skinny(40%)     ← grid stripped (warning), skinny(40%) applies
a
// --
b
// end inner

// end outer
```

Grid-in-grid and skinny-in-skinny stay blocked (at any depth, not just the immediate
parent: `skinny > grid > skinny` strips the innermost skinny). Structure is never
depth-dependent — the group/wrapper always still forms.

## Degradation analysis (mandatory)

No activation rule changes: `//` and `/` lines parse exactly as before, and inert prose
stays inert byte-for-byte. The change is strictly *permissive* on already-active
documents — every document that rendered without layout warnings renders identically;
documents that previously warned now either render more layout (the author's stated
intent honored) or warn per-command. **Corpus check** (`strikedown/`): one directive in
the corpus, a top-level `/skinny(90%)` in `main.md` — no nesting, meaning unchanged.

## Decision

Dictated by Jack, 2026-07-16: **candidate B**. The layout-level rule is per layout
command — one level of nesting per command, enforced with per-command counters in the
parser. On a mixed opener, **only the colliding command is stripped** (partial strip);
the others still apply. Warnings name the stripped command
(`group 'inner': grid ignored (already inside a grid)`).

## Canonical examples

Skinny inside a grid cell — both apply, no warnings:

```
// outer grid(2)

/skinny(50%)
a narrow paragraph in the left cell

// --

the right cell

// end outer
```

Grid inside a grid — inner group forms, its `grid` is stripped with a warning:

```
// outer grid(2)

// inner grid(2)
a
// --
b
// end

// --

c

// end outer
```

Mixed opener, partial strip — inside a grid, `// inner grid(2) skinny(50%)` keeps
`skinny(50%)` and drops only `grid(2)` (one warning).

## Future direction

Every future layout command gets its counter for free (counters are keyed by the command
enum's tag). Future *non-layout* commands (color, spacing…) never touch a counter and so
never collide. If a command someday genuinely composes with itself (nested indentation?),
that is a semantics decision for its own design note — the per-command counter is the
default, not a law of the tree.
