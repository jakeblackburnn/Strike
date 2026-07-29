# Degradation

Every superset form is inert prose in a document that never activates it. That
is what lets you point strike at a folder of ordinary markdown and get the same
document back — and it is why superset syntax is strict rather than forgiving.

Each line below *looks* like a strikedown feature and is deliberately not one.
Read this page rendered, then read the source: every one of them is a plain
paragraph.

## Directives that don't parse cleanly

// just a comment here

// box glow(5)

// --

//foo

/usr/bin/env zsh

/skinny(50%) with trailing text

/color(red)

/collapse(true)

/indent(x)

:thin-grid grid(2) skinny(80%)

The rule is the same in every case: a `//` line is a directive **only if the
whole line parses** — every command recognized, every argument valid. One typo
and the line is text. So a stale document renders as visible prose rather than
silently wrong layout, and a `//` you wrote as a comment stays a comment.

## Inline near-misses

[x].color(bright)

[strike](https://github.com/jakeblackburnn/Strike).color(muted)

a * b * c and 5 * 4 * 3

The book costs $5 and the pen costs $10.

$HOME and $PATH are set

.item

(name)# not a heading

Unknown color roles fail the parse. A link wins its own `[`, so the `.color()`
after one is literal text. Emphasis and math delimiters have to hug their
content, so asterisks and dollar signs in prose stay put.

## The one thing to remember

> [!IMPORTANT]
> If a line of yours reads like prose, it renders like prose. Activation is
> always explicit and always strict — there is no partial credit, and no form
> that changes meaning based on something you cannot see.
