# Layout & commands

This is the superset half of strikedown: arranging content from plain text.
Two directive families do all of it.

## Groups — `//` lines

A `//` line brackets content into a **group**; `// --` starts the next
section; `// end` closes it. Commands on the opener arrange the sections.

// two_col grid(2)

**Left section**

Sections fill left to right. Each one holds as many content elements as you
want — paragraphs, lists, code, anything.

// --

**Right section**

The group is named `two_col`, but the name is optional: `// grid(2)` opens a
nameless group just the same.

// end two_col

## Single commands — `/cmd()` lines

A `/command()` line applies one command to the **very next content element**,
with no closer to remember.

/skinny(60%)

This paragraph renders at 60% of the body column, centered in it. Only this
paragraph — the next one is back to full width.

Commands chain: consecutive `/cmd()` lines all bind to the same element,
nesting innermost-last.

/skinny(70%) 

/center()

Narrow *and* centered, from two stacked directives.

## The commands

/indent()

`grid(n)` arranges a group's sections in n columns. `skinny(N%)` and `wide(N%)`
are one width control with two names, meeting at 100%.

// wide_demo wide(115%)

This group bleeds past the reading column on both sides — useful for a wide
table or a figure that suffocates at the body width.

| a wide table | column two | column three | column four |
| --- | --- | --- | --- |
| room to breathe | without | squeezing | the text |

// end wide_demo

/center()

`center()` centers the text within whatever contains it.

// muted_aside color(muted)

`color(role)` sets a theme *role* — `accent`, `muted`, or `fg` — never a
concrete color, so text follows the reader's theme. Inline, the same command
spells [a single accent phrase].color(accent) mid-sentence.

// end muted_aside

// faq collapse()

**`collapse()` folds a group behind its first element**

The first content element is the *leader*: it stays visible and becomes the
control. Everything after it folds away until the reader opens it.
`collapse(open)` starts expanded instead.

Other commands on the same group apply to the folded body, not the leader.

// end faq

## Indentation

`indent(n)` insets first lines by n steps, and leading whitespace on a
paragraph is shorthand for one step:

  This paragraph starts with two spaces, so it is indented one step — no
  directive needed. The rule reaches paragraphs only; a heading or list wants
  `indent(n)` if it should move.

/indent(3)

This one uses the command, three steps deep.

## Nesting rules

Groups nest freely, but **each layout command applies at most once** along any
chain of containers: a `skinny` inside a `grid` cell is fine, a `grid` inside a
`grid` is not. The inner one is ignored with a warning on stderr, and the group
still forms — layout mistakes never break your document's structure.

// outer grid(2)

/skinny(80%)

A narrow paragraph inside the left cell. Different commands, so this nests
happily.

// --

The right cell.

// end outer
