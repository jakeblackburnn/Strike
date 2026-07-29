# 008 — Raw lists (`. item`)

**Status: accepted** (decision dictated by Jack, 2026-07-20)

## Problem

An unordered list whose items carry no visible marker — a bare stack of
short lines (credits, link rolls, definition-ish runs) that should read as a
list structurally but render without bullets or list indentation. Markdown
can only fake it with hard-wrapped paragraphs, which merge on soft-wrap, or
bulleted lists, which insist on their dots.

## Terminology

- **Raw list** (also *plain list*) — an unordered list rendered with no item
  marker and no marker indentation.

## Candidates

### A — `--` marker

```
-- first item
-- second item
```

Visually kin to `-`; reads as "a dash-list minus the dash." Degrades as a
paragraph today (`--` is not an HR, which needs three). Slight collision
surface with em-dash-style prose openers.

### B — `.` marker

```
. first item
. second item
```

The tersest form; a lone dot reads as "no marker." No relation to any
existing block form (`1.` needs digits first). Prose lines beginning `. `
are vanishingly rare (an ellipsis is `...` with no space).

### C — `~` marker

```
~ first item
```

Low collision risk but no visual kinship with lists, and `~` already
signals strikethrough inline.

### D — no new marker: a `/plain()` command on a normal list

Reuses the command machinery, but a `/cmd()` wrapper's styling lands on the
group wrapper, where user-agent list styling overrides it — the attribute
would need new machinery to reach the list itself, or reader CSS descendant
rules. The one candidate that isn't a marker was rejected for that
mismatch.

## Degradation analysis (mandatory)

A, B, C are all new markers with the same activation shape as every list
marker: a line starting `<marker><space>` begins a list, including
interrupting an open paragraph (the `isBlockStart` companion). In a
document that never starts a line with the marker + space, nothing changes.
For the chosen B: corpus check — zero lines matching `^\s*\. ` in
`strikedown/` and `docs/` at decision time. D degrades via the command
family's parses-cleanly rule and activates nothing new.

## Decision

**Candidate B — the `.` marker.** Dictated semantics:

- `. item` is an unordered list item with no rendered marker. Raw lists are
  full lists otherwise: indentation-nesting (≥ 2 columns), `[ ]`/`[x]` task
  boxes, lazy continuation, blank-line tolerance — identical to `-` lists.
- Marker kinds don't mix at one level: a `. ` item at the same indent as an
  open `-`/`*`/`+`/ordered list ends that list and starts a sibling raw
  list (the same rule that already separates ordered from unordered).
  Nesting a raw list inside a bulleted one (and vice versa) is fine.
- Rendering: no marker, no marker indentation — items sit at the list's own
  left edge. HTML: `<ul class="sx-plain">`; the class is the hook, reader
  CSS removes bullets and padding. A bare fragment without reader CSS shows
  default bullets — acceptable degradation, structure intact.

## Canonical examples

```
. one
. two
. three
```

→ `<ul class="sx-plain">\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ul>`

Mixed markers split:

```
- bulleted
. raw
```

→ `<ul>…<li>bulleted</li>…</ul><ul class="sx-plain">…<li>raw</li>…</ul>`

Degradation: `.item` (no space) and `...` stay prose; a paragraph line
followed by `. next` now breaks into a raw list (the activation, by
design).

## Future direction

- Raw *ordered* lists (numbering suppressed but semantically ordered) are
  not defined; if wanted, they get their own marker decision.
- Tighter/looser raw-list spacing is renderer styling, not language.
