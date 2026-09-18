# 021 — The spacer block (`...`)

**Status: shipped** (2026-09-15)

## Problem

strikedown has no way to insert deliberate extra vertical space between two
elements. `snug()` (019/020) does the opposite — it tightens the seam
between two blocks — but nothing opens one up. Authors who want visual
breathing room between two sections have no superset form to reach for.

## Terminology

- **Spacer** — a content element with no text and no reader-visible mark,
  whose only effect is the vertical space it occupies.

## Candidates

### A — repeated dots: `...`

```
Paragraph one.

...

Paragraph two.
```

Mirrors the rule's own grammar exactly (`isHorizontalRule` already accepts
three-or-more of one repeated character — `-`, `*`, or `_`; dots are a
natural sibling of that rule, not a new grammar shape). Reads visually as a
pause/gap. Only near-miss: `isPlainItem`'s raw-list marker is `. ` (dot
*then a space*) — disjoint from an unbroken run of dots, so no collision.

### B — bracketed keyword: `[space]`

```
Paragraph one.

[space]

Paragraph two.
```

A literal, self-documenting token instead of a symbol. Zero ambiguity with
any existing syntax. Easiest to extend with an argument later
(`[space(2)]`), but introduces a new bracket-led bare-line grammar shape
that nothing else in the language uses today.

### C — repeated tildes: `~~~`

Same "repeated char" shape as A. Rejected: in mainstream Markdown
(CommonMark, GFM) `~~~` is a well-known alternate code-fence marker, so
authors coming from other Markdown dialects would likely misread it as a
fence even though strikedown doesn't implement that form.

## Degradation analysis (mandatory)

- A line of fewer than three dots, or dots mixed with any other character
  (including a trailing space), fails the predicate and falls through to
  ordinary paragraph parsing — inert prose, exactly like the horizontal
  rule's own degradation story.
- `isPlainItem`'s raw-list marker (`. `, a dot immediately followed by a
  space, `docs/reference/design/008-raw-lists.md`) cannot collide: the
  spacer trigger requires *only* dots on the whole trimmed line, so any
  line containing a space is never eligible in the first place.
- **Corpus check** (2026-09-15): zero hits for a standalone dot-only line
  anywhere under `docs/` (checked `docs/example/**/*.sx` and every
  `docs/reference/*.md`; the handful of literal `...` occurrences found are
  mid-sentence ellipses inside prose paragraphs, never a line on their own).

## Decision

**Candidate A.** Dictated semantics:

- Three or more unbroken `.` characters, and nothing else, on an otherwise
  blank line (surrounding whitespace trimmed, same as the horizontal rule)
  produce a spacer block.
- No argument, no size options — one fixed amount, defined once in CSS.
- Not a `Command`: does not participate in `//` openers or `/cmd()` chains,
  carries no layout/structural classification, and cannot combine with
  other commands. It is its own `Block.Kind`, exactly like `rule`.
- Renders as an empty, non-content marker element (`aria-hidden`) whose CSS
  gives it a fixed height.

## Canonical examples

```
Paragraph one.

...

Paragraph two.
```
→
```html
<p>Paragraph one.</p>
<div class="sx-spacer" aria-hidden="true"></div>
<p>Paragraph two.</p>
```

Degradation: `..` (two dots) is an ordinary paragraph; `. .` (dot, space,
dot) is a raw list item (008), not a spacer; `. next` is the same raw list
item form, untouched.

## Future direction

- A sizing knob (steps, named sizes, or explicit units) can be added later
  without touching this base form — most likely as a value carried on the
  same `Block.Kind.spacer` payload, or, if it ever needs to compose with
  other commands, promoted into the `Command` union at that point. Neither
  is decided now.
- The PDF backend maps the fixed amount to its own vertical-space primitive.
