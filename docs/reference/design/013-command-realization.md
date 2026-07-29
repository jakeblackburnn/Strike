# 013 — Command realization by content-element type

**Status: partially accepted** (the `indent` × list cell was dictated by Jack,
2026-07-25, and is shipped; every other cell is **open** — this note is the
place they get decided, not a record that they have been.)

> Read this as a working model, not settled spec. `docs/reference/STRIKEDOWN.md` carries
> only the cells that have actually been decided; everything marked *open*
> below is subject to change and nothing should be implemented from it.

## Problem

A command has one meaning, but the content elements it lands on are not
alike, and the same rendering instruction does different things to them.
`indent` is where this surfaced: it emits CSS `text-indent`, which on a
paragraph is exactly right — the typographic tab note 011 asked for — and on
an ordered list is plainly wrong, dropping the tab *between* the number and
the item instead of moving the line. The list marker did not move because
`text-indent` shifts text, and a list's marker column is not text.

Nothing in the language or the model says how a command's meaning maps onto
different element types, so each new command has been decided one element at
a time, in the emitter, by whichever CSS property seemed right at the time.
That is fine while there are six commands and eight element types and most
combinations are rare — it stops being fine the moment images, figures, or a
second backend arrive, because PDF has to answer the same questions with none
of CSS's inheritance to hide behind.

## Terminology

- **Meaning** — what a command says, backend-neutral: "inset this element
  from the left by n steps". One per command, recorded in `docs/reference/MODEL.md`.
- **Realization** — how one element type carries out that meaning. Per
  (command, element type) pair, and a backend's business.
- **Flowing prose** — an element whose left edge is simply where its text
  starts: paragraph, heading, display math.
- **Structured box** — an element that owns a left edge as part of its form:
  a list (its marker column), a blockquote (its bar), a code block (its padded
  background), a table, a rule.

## The principle

A command means one thing. Each content element type realizes that meaning in
the way that keeps the element itself intact. Where an element's own structure
occupies the space a command wants to act on, the structure moves with it.

The flowing-prose / structured-box split above decides most of the open cells
below, and is the first thing to try when a new command or element arrives.
It is a heuristic for finding the right answer, not a rule that produces it —
`center` is a case where it may not survive contact (see below).

## The matrix

Commands down, element types across. **shipped** = decided and implemented;
**open** = current behavior is an accident of implementation, not a decision.

| | paragraph / heading | list | blockquote | code block | table | rule | display math |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `indent(n)` | first-line inset — *shipped* (011) | whole list shifts, markers included — **shipped** (2026-07-25) | *open*: bar stays, inner paragraphs inset | *open*: box stays, text insets | *open*: box stays, cell text insets | *open*: no effect | *open, blocked* |
| `center()` | text centers — *shipped* (005) | *open*: item text centers, markers hang | *open*: quote text centers | *open*: source text centers | *open*: cell text centers | *open*: no effect | *open, blocked* |
| `skinny(N%)` / `wide(N%)` | width on the box — uniform | uniform | uniform | uniform | uniform | uniform | *open, blocked* |
| `color(role)` | text takes the role — *shipped* (006) | uniform | element color wins — *shipped* (006) | element color wins — *shipped* (006) | uniform | *open*: no effect | *open, blocked* |
| `grid(n)` / `collapse()` | group-only by construction | | | | | | |

### The decided cell: `indent` on a list

A list owns its marker column, so `indent` moves the **whole list** — marker
and item together — rather than the item text. In the HTML backend that is
`margin-left`, paired with `text-indent:0` so an enclosing group's inherited
`text-indent` doesn't nudge the item text on top of the shift. Nested
sublists are not shifted again: the parent list already moved, and the
sublist's own indentation is list nesting, not this command.

Note that a list can only ever *be* indented through a group or a `/indent(n)`
line — leading whitespace before a list marker is list nesting, and note 015
confines the whitespace spelling to paragraphs, so it never reaches a list.

### `center` is where the heuristic gets tested

The flowing/box split says a structured box should center *itself*
(`margin-inline:auto`) rather than its contents. That is almost certainly
right for a code block (centering source text is meaningless) and probably
right for a table. It is not obviously right for a list — an author writing
`/center()` above a short list may well want the items centered as a block of
text, markers and all, which is a third realization neither option covers.
Left open deliberately; `center` on these elements is rare enough that the
current behavior (text-align inherits into everything) has never been
questioned in real content.

### `skinny` / `wide` are the uniform family

A width is a width: every block-level element is a box, and the same
declaration works on all of them. This is the one family with no per-type
divergence, which is worth stating because it shows the matrix is not
inherently sparse — some commands genuinely do mean one thing everywhere.
The open question there is behavioral, not semantic: a code block or table
narrowed below its content's natural width overflows, and nothing decides
whether that scrolls, wraps, or is the author's problem.

## Known gap: display math has nothing to hang attrs on

Display math emits raw `\[…\]` for MathJax with no wrapper element, so it
silently drops **every** attribute — indent, center, color, and width alike.
Every math cell above is marked *blocked* rather than *open* for that reason:
deciding any of them means first deciding whether math gets a wrapper
element, which is a rendering decision with its own consequences (MathJax's
own layout, display-block spacing, PDF's entirely different math path). Not
fixed here; flagged so it isn't rediscovered.

## Future elements

Images, figures, embeds, and footnotes are all on the roadmap, and each one
adds a column here. The obligation this note creates: **a new content element
declares its realization for every existing command**, the same way a new
command already has to classify itself through `isLayout`/`isStructural`. For
most elements that is one sentence — "it's a structured box, it follows the
box column" — but it must be written rather than inherited by accident from
whichever CSS the emitter happens to produce.

## Implementation note

Today a group's `indent` is emitted once on the group's wrapper and reaches
flowing children through CSS inheritance; the list arm overrides that with its
own realization, using an inherited-indent value threaded down the emit walk.
That is the minimal shape for one box-mode element.

If blockquote, code, and table also move to box realizations, the cleaner
shape is for a group carrying `indent` to stop emitting `text-indent` on its
wrapper entirely and let every child emit its own realization from the
threaded value — inheritance stops paying for itself once most children have
to override it. The plumbing for that already exists; only the group arm and
the tests would change. Recorded so the next pass doesn't re-derive it.

The PDF backend will not have CSS inheritance at all, and will have to
realize every cell explicitly. A matrix that is written down is the thing that
makes that port mechanical instead of a second round of guessing.
