# 007 — The `collapse` command (`collapse()`, `collapse(open)`)

**Status: accepted** (decision dictated by Jack, 2026-07-20)

**Amended 2026-07-22** (visual fix, implementation only — no language change): the
open-state card background was specified as "lighter than the page," which has no
answer on a light theme (there's nowhere lighter to go than white). See "Visual
treatment" below for the corrected reader-CSS behavior.

## Problem

Long reference material — FAQ answers, digressions, appendix detail — costs
vertical space whether or not the reader wants it. Plain text has no way to
say "this run of content folds away behind its first line." A group already
brackets exactly the right unit; what's missing is a command that makes the
group *collapsible*: closed by default, opened by the reader, with a visible
always-present leader line to click.

## Terminology

- **Collapsible group** — a group carrying the `collapse` command; its
  content hides until the reader opens it.
- **Leader** — the group's first content element, which stays visible when
  the group is collapsed and is the open/close control (the whole element is
  the hitbox, with an always-visible indicator).
- **Empty bar** — the anonymous leader rendered when the group has at most
  one content element: a bare clickable bar with only the indicator.

## Candidates

The syntax was never in question — `collapse` rides the note 001/002 command
machinery (group openers and `/collapse()` lines) like every command. The
open design point was its relationship to the layout-level rule:

### A — non-layout command (nesting allowed)

Like `color`: `collapse` touches no depth counter, so collapsible groups
nest (dropdown trees, nested FAQs). Costs: a second exception to "commands
are layout," and deep nesting invites structure that reads poorly when
printed (the planned PDF backend would have to invent an expansion policy).

### B — layout command (the rule applies)

`collapse` counts under the per-command layout-level rule: a collapsible
group inside a collapsible group keeps its group but the inner `collapse` is
stripped with a warning, exactly like grid-in-grid. One level of folding per
chain; other commands (`grid`, `skinny`, …) combine freely on the same
opener or inside the folded body.

## Degradation analysis (mandatory)

Both candidates share the command family's story: `collapse` only means
anything inside a `//` opener or a `/collapse()` line that parses cleanly.
`collapse(anything-else)` — `collapse(true)`, `collapse(5)` — deactivates
its whole line (the strict-typo rule), and prose that mentions the word
collapses nothing. A document that never activates it is untouched. Corpus
check: zero hits for `collapse(` in `strikedown/` at decision time.

## Decision

**Candidate B.** Dictated semantics:

- `collapse()` — the group starts **closed**. `collapse(open)` — the group
  starts **open**. Any other argument deactivates the line (and, as with
  every command, the parens are required — `// faq collapse` is a group
  named `faq` with a prose word after it, deactivating the line). State is
  per page load; the renderer persists nothing.
- `collapse` is a **layout command**: it makes its target a layout element
  and counts under the per-command layout-level rule (note 004). Collapse
  inside collapse strips the inner command with a warning; the group still
  forms.
- **Leader**: when the group holds two or more content elements, its first
  element (the first block of the first section) is the leader — always
  visible, whole-element hitbox, indicator always shown. With one element or
  none, the leader is the **empty bar** and everything folds beneath it.
- Other commands on the same group apply to the *folded body*, not the
  leader (a `grid(2)` collapsible group folds a grid; the leader is never a
  grid cell).
- HTML backend: `<details class="sx-group sx-collapse">` (plus `open` when
  `collapse(open)`), the leader inside `<summary>` (the empty bar is
  `<summary class="sx-collapse-bar">`), and the sections inside a
  `<div class="sx-collapse-body">` that carries the group's other style
  attributes. Without reader CSS this degrades to the platform's native
  disclosure widget — still functional. (A block leader inside `<summary>`
  is spec-loose for `<p>` but universally rendered; headings are valid.)

## Canonical examples

```
// faq collapse()

**What is strikedown?**

A typography-first superset of markdown.

// end faq
```

→ `<details class="sx-group sx-collapse"><summary><p><strong>What is
strikedown?</strong></p></summary><div class="sx-collapse-body"><p>A
typography-first superset of markdown.</p></div></details>`

```
/collapse(open)

only one paragraph here
```

→ the empty-bar form, open: `<details class="sx-group sx-collapse"
open><summary class="sx-collapse-bar"></summary><div
class="sx-collapse-body"><p>only one paragraph here</p></div></details>`

Degradation: `/collapse(true)` and `// box collapse(5)` are ordinary
paragraphs; a `// inner collapse()` group inside an open collapsible group
forms as a plain group with a warning naming `collapse`.

## Visual treatment (reader CSS, `src/shell.zig`)

Not part of the language — the HTML backend only emits the classes above; all of
this is `--collapse-*` theme tokens and rules the reader stylesheet applies to them.
Recorded here because the first cut of it was wrong and worth not repeating.

- **Closed** (`.sx-collapse`, no `[open]`): background is `--collapse-closed-bg`, a
  low-alpha tint (per-theme hue on light seasons, plain black on dark ones) painted
  over the page background — reads as recessed regardless of theme, since darkening
  a light *or* dark background both work.
- **Open** (`.sx-collapse[open]`): background is `--collapse-open-bg`. On dark
  themes this is a low-alpha *white* tint (lightening a dark background reads fine,
  so the group still reads as emphasized). On light themes lightening isn't
  possible, so `--collapse-open-bg` is just `var(--bg)` — the card blends back to
  page color — and `--collapse-shadow` (a real `box-shadow`, `none` on dark themes)
  supplies the "sticks out" cue instead. Elevation-by-shadow on light, elevation-by-tint
  on dark is the general pattern for either state; wire a new season's tokens
  accordingly rather than assuming a lighter fill always works.
- **Hitbox affordance**: the `<summary>` (leader or empty bar) carries its own
  negative margin matching the card's padding, so its background paints edge-to-edge
  with the card — then `summary:hover` gets a flat low-alpha black overlay
  (`rgba(0,0,0,.07)`) on top of whatever the card's current background is, closed or
  open. This darkens only the clickable row, never the folded body, making the
  hitbox legible independent of theme or state.

## Future direction

- Reader-side persistence of open state (needs a stable per-group key —
  likely name + position) is deliberately left out.
- A `collapse(open)`-style argument vocabulary could grow (e.g. `sticky`)
  only through a new note.
- The PDF backend will render collapsible groups fully expanded (leader
  styled as a run-in heading is the likely shape); folding is a screen
  affordance, not document meaning.
