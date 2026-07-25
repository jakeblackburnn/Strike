# 011 — The `indent` command and literal-tab indentation (`indent(n)`, `⇥`)

**Status: shipped** (decision dictated by Jack, 2026-07-21; rendering bug
corrected and merged into `docs/STRIKEDOWN.md` 2026-07-22)

## Problem

Strikedown has no way to push a single content element in from the left
margin — the everyday typographic move of indenting a paragraph, a heading,
an aside. Groups can narrow (`skinny`) and center (`center`) content, but
nothing shifts it. And the most natural spelling for the everyday case is
not a directive at all: it's pressing tab, the way indentation has been
typed since typewriters.

## Terminology

- **Indent step** — one unit of first-line inset (the HTML backend renders a
  step as `2rem` of CSS `text-indent`, an *inherited*, first-line-only
  property — it never shifts the rest of a wrapped block, and set once on a
  group's wrapper it reaches every descendant block independently through
  ordinary CSS inheritance).
- **Tab prefix** — one or more literal tab characters at column 0 of a
  content line; each tab is one step.

**Correction (2026-07-22)**: the implementation shipped against this note
originally rendered indent as `margin-left`, which shifted an entire block
(every line, not just the first) and, on a group, shoved the whole wrapper
box rightward instead of indenting its contents. Jack caught this reviewing
`test.md`'s `// collapse() indent(1)` example — the collapsible group's body
moved as one unit rather than each paragraph inside gaining its own
first-line indent. Fixed by switching the emitted CSS property to
`text-indent`; the "insets accumulate by nesting" semantics below were also
corrected in the same pass (see the nesting bullet).

## Candidates

### A — literal tabs only

```
	This paragraph is indented one step.
		# A heading, two steps in
```

A leading tab indents the block it starts; more tabs, deeper. No command
form. Simplest spec, but it would be the first typography feature living
outside the command machinery — a group could not be indented as a unit,
and aliases (note 010's direction) could never name it.

### B — command only (`indent(n)`)

```
/indent(2)

This paragraph is indented two steps.
```

Rides notes 001/002 unchanged: `indent(n)` in group openers and `/indent(n)`
lines. Zero parser ambiguity, but writing a directive line above every
indented paragraph loses the "just press tab" ergonomics that motivated the
feature.

### C — both: literal tab as sugar for the command

Candidate A's spelling desugaring to candidate B's data: a tab prefix writes
the same `attrs.indent` an explicit `indent(n)` writes. One data path, two
spellings; groups and aliases get it through the command, prose gets it
through the tab key.

## Degradation analysis (mandatory)

- **Tab prefix**: a tab-led line in strike today fails every block check
  (the parser trims only spaces) and falls into paragraph prose, where HTML
  collapses the whitespace — leading tabs are inert, so activating them
  changes nothing that currently renders meaningfully. CommonMark proper
  would treat such a line as an *indented code block*; strike has never
  implemented indented code (fenced only, deliberately), so no strike
  document loses a code block. Space-led lines stay trimmed and inert —
  only the literal tab character activates.
- **Command**: the family's shared story — `indent` means something only in
  a cleanly parsing `//` opener or `/indent(n)` line. `indent(0)`,
  `indent(x)`, `indent` without parens all deactivate their line (the
  strict-typo rule).
- **Corpus check** (2026-07-21): zero hits for `^\t` and zero hits for
  `indent(` across `strikedown/`.

## Decision

**Candidate C.** Dictated semantics:

- `indent()` — one step. `indent(n)`, n ≥ 1 — n steps. Any other argument
  deactivates the line. Works in group openers and `/indent(n)` lines like
  every command.
- A **tab prefix** on a content line indents that one block: the tabs are
  stripped, the remainder parses through the normal block chain, and the
  resulting block carries `indent = tab count` directly on its attrs — no
  group is formed. Tabs count only at column 0; a space/tab mix stays inert.
- **Non-layout command**, like `color`: nesting *scopes*, it doesn't stack —
  an inner `indent(n)` overrides the inherited value for its own subtree
  (plain CSS `text-indent` semantics, the same inner-wins cascade `color`
  already uses), so `indent` never touches a layout-depth counter and nests
  freely. (Corrected 2026-07-22 — see the terminology note above; the
  original "insets accumulate" language described `margin-left`'s incidental
  box-stacking geometry, not a deliberate feature, and no code ever actually
  summed nested values.)
- **Exclusions**, where leading whitespace already means something or the
  line isn't content: a tab prefix before a list-marker line stays list
  indentation (nesting, exactly as today), and a tab before a directive line
  (`//`, `/cmd()`, `:`) leaves the line inert prose — directives are
  column-0 forms.
- A tab-led line **starts a new block** (the `isBlockStart` companion): it
  breaks a preceding paragraph and stops quote lazy-continuation.
- HTML backend: one step is `text-indent:2rem`, emitted by the shared style
  helper — so it lands on any element the attrs land on. Because
  `text-indent` is inherited and first-line-only, setting it on a group's
  wrapper reaches every child paragraph/heading inside independently (each
  gets its own first line inset, no explicit style on the child) without
  shifting the wrapper box itself; a tab-prefixed or `/indent(n)`-bound
  single block gets it directly, indenting only that block's own first line.

## Canonical examples

```
	indented paragraph
```

→ `<p style="text-indent:2rem">indented paragraph</p>`

```
		## deep heading
```

→ `<h2 id="deep-heading" style="text-indent:4rem">deep heading</h2>`

```
/indent(2)

pushed in
```

→ `<div class="sx-group" style="text-indent:4rem"><p>pushed in</p></div>`

A group with `indent()` applied to more than one paragraph — each child
gets its own first-line indent purely by inheriting the wrapper's
`text-indent`, no per-child style:

```
// aside indent()

first paragraph

second paragraph

// end aside
```

→
```html
<div class="sx-group" style="text-indent:2rem">
<div class="sx-group-sec">
<p>first paragraph</p>
<p>second paragraph</p>
</div>
</div>
```

Nested indents override rather than accumulate — the inner group's own
value wins for its own subtree, it is not added to the outer one:

```
// outer indent(2)

// inner indent()

para

// end inner

// end outer
```

→ the outer wrapper carries `text-indent:4rem`; the inner wrapper carries
`text-indent:2rem` (one step), not `6rem`.

Degradation: `/indent(0)` is an ordinary paragraph; a tab before `- item`
is list nesting, not an indented list; `	// aside grid(2)` is inert prose.

## Future direction

- Step size is the HTML backend's choice (`2rem`), not language semantics;
  a future settings surface (the `:` namespace, note 010) could make it
  tunable.
- Full margin control (left/right insets on the whole block box, not just
  its first line) remains open for a later margins note; `indent`
  deliberately stays a first-line typographic-tab primitive, not a margin
  command.
- The PDF backend maps steps to its own paragraph-indent metric.
