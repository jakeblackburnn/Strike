# 015 — Paragraph indentation by leading whitespace

**Status: shipped** (decision dictated by Jack, 2026-07-29)

Supersedes the **tab-prefix** spelling of `docs/design/011-indent.md`. The
`indent(n)` command that note decided is unchanged and remains the way to ask
for depth.

## Problem

Note 011 gave indentation two spellings: the `indent(n)` command, and a
**tab prefix** — literal tab characters at column 0, one step each, applying to
whatever block the line starts. The command half works. The tab half has three
problems that only showed up in use:

- **It is invisible and unforgiving.** Whether a line indents depends on a
  character you cannot see, and on it being a tab rather than the spaces most
  editors insert. A writer who presses tab in one editor and space-space in
  another gets different documents.
- **It applies to every block type**, so a tabbed heading, quote, or table
  silently indents — element types where the typographic move is rarely what
  was meant, and where the command spelling is clearer about intent.
- **It doesn't actually work everywhere it claims to.** The spec promises a tab
  prefix "starts a new block … exactly like any other block-starting form", but
  after a list item it is swallowed as a lazy continuation: the list parser
  trims leading whitespace before asking whether the line interrupts the item,
  so the tab is gone by the time anything looks for it. A rule with a silent
  exception is worse than no rule.

Meanwhile the everyday case — indenting a paragraph — is what people actually
reach for, and they reach for it by putting *some* whitespace in front of the
line without thinking about how much or which kind.

## Terminology

- **Simple paragraph** — a content element that is a paragraph: flowing text at
  block position, not a heading, quote, list, table, code block, math block, or
  directive.
- **Indent step** — unchanged from note 011: one unit of first-line inset (HTML:
  `2rem` of inherited `text-indent`).

## Candidates

### A — Any leading whitespace, one step, paragraphs only

```
This paragraph is flush left.

  This one is indented, because it starts with whitespace.

	So is this one — a tab is whitespace too.
```

The trigger is "is there anything before the text", not "how much" and not
"which character". Two spaces, four spaces, one space, a tab: all one step.
Deeper indents are `/indent(n)`, the spelling that can actually say *three*.

Reads the way people already type, works identically across editors and tab
settings, and confines the whole feature to the one element type where a
first-line inset is the obvious reading. The cost: the source can't express
nesting visually — eight spaces looks deeper than two but renders the same.

### B — Proportional: whitespace width maps to steps

```
  two spaces      → 1 step
    four spaces   → 1 step
        eight     → 2 steps
```

Lets the source *look* like the output, which is genuinely attractive for
outline-ish writing. But it makes invisible whitespace load-bearing in exactly
the way that burned note 011: one-space vs two-space now differ, a tab is worth
some number of columns nobody agrees on, and a re-indenting editor silently
rewrites meaning. It also re-introduces two ways to say "three steps" that can
disagree on the same line.

### C — Keep tabs only, fix the list bug

Narrowest change: leave the tab prefix as specified and make it interrupt list
items properly.

Rejected: it fixes the symptom and keeps all three underlying problems. The
character stays invisible, spaces still do nothing, and every block type still
responds.

## Degradation analysis (mandatory)

The direction is a superset form becoming *narrower*: tabs before headings,
quotes, lists, tables, code fences, and directives stop meaning anything, which
can only return documents to plain-markdown behavior.

The one direction that *adds* meaning is a space-indented paragraph, which in
plain markdown is insignificant whitespace. Two things bound the risk:

- Only a **paragraph's first line** is examined, and only when a paragraph is
  actually starting. An indented line following a paragraph line is a soft-wrap
  continuation, exactly as before — so wrapped prose that happens to be indented
  is untouched.
- CommonMark's 4-space indented code block is not a strike form, so no existing
  meaning is displaced.

**Corpus check** — every `.md`/`.sx` under `strikedown/`, fenced code excluded,
looking for paragraph-starting lines that begin with whitespace: **one hit**,
`data_mining/11_graph_mining.md:158` (`   Example: starting from node $A$…`),
which reads as a deliberate indent under a numbered point. Zero hits in
`docs/`. The rule activates on essentially nothing that exists, and where it
does activate it does what the author appears to have meant.

## Decision

**Candidate A.**

A **simple paragraph** whose **first line** begins with any whitespace — one
space, two, four, or a tab — carries **one** indent step, identical to
`indent(1)`. The amount and kind of whitespace are not significant; the
convention is two or four spaces. No other element type responds to leading
whitespace: headings, quotes, lists, tables, code blocks, math blocks, and all
three directive families ignore it exactly as they did before, and use
`indent(n)` when they want an inset.

Depth beyond one step is `/indent(n)` or a group carrying `indent(n)`. The tab
prefix as a distinct spelling is gone — a tab is now simply one of the
whitespace characters that triggers the one-step rule.

Two consequences, both deliberate:

- **An indented paragraph must be preceded by a blank line.** Leading
  whitespace no longer starts a block, so an indented line directly after a
  paragraph line soft-wraps into that paragraph — plain-markdown behavior, and
  the reason wrapped prose can't accidentally indent.
- **Inner wins, as everywhere else.** A paragraph that is both
  whitespace-indented and targeted by `/indent(3)` renders at one step: its own
  attribute beats the wrapper's, the same cascade `color` uses. Don't write
  both.

This also retires the list-item bug in the Problem section by construction —
there is no longer a whitespace-led *block form* for a list to swallow, and an
indented line inside a list item is an ordinary continuation.

## Canonical examples

```
flush paragraph                    →  <p>flush paragraph</p>
  two-space paragraph              →  <p style="text-indent:2rem">…</p>
    four-space paragraph           →  <p style="text-indent:2rem">…</p>
⇥ tabbed paragraph                 →  <p style="text-indent:2rem">…</p>

  # not an indented heading        →  an ordinary <h1>
  > not an indented quote          →  an ordinary <blockquote>
  - not an indented list           →  an ordinary <ul>
  // g grid(2)                     →  an ordinary group opener

para line                          →  one paragraph, "para line continued",
  continued                           no indent (soft-wrap continuation)
```

## Future direction

If visually-nested source ever becomes worth having, it belongs to a block form
that is *about* nesting (an outline element), not to whitespace on a paragraph —
the lesson of candidate B is that indentation width should never be the carrier
of meaning that a command can state outright.

The realization matrix (`docs/design/013-command-realization.md`) is unaffected:
this note changes only how a paragraph *acquires* `indent`, never what `indent`
means on any element type.
