# Why the base branches exist

`main`/`slopbox` are the AI-written 0.1.x line: a fast, broad proof of concept for
strikedown's design (groups, commands, citations, a full reader). It did its job —
the design notes in that history settled real questions — but it was never meant to be
the code that ships. `README.md` on those branches says as much: 0.1.x nails down
decisions, 1.0.0 is a slower, human-directed rewrite.

`base_md` and `base_sx` are where that rewrite starts. Not a port, not a cleanup pass —
a restart. Their history is deliberately disconnected from `slopbox`'s (an orphan root
commit): nothing here is inherited, everything here is decided again, on purpose, at a
much smaller scale.

## What each branch is

- **`base_md`** — the toolkit spine, markdown only. Two-stage rendering (parse → tree →
  emit), a line-based block loop, a flow-joined inline chain, one CLI subcommand
  (`strike render`). No server, no config, no site model. If it isn't load-bearing for
  the *architecture*, it isn't here yet.
- **`base_sx`** — `base_md` plus the smallest possible superset form: groups
  (`// name` / `===` / `// end name`), with no commands and no styling. It exists to
  prove one thing: that a superset form can degrade to inert prose in a document that
  never activates it, and that the parser can tell the difference cleanly. Everything
  else strikedown eventually wants — layout commands, color, citations, aliases — is
  named as backlog, not built.

## What v0.0.1 deliberately is not

Not feature-complete markdown (no lists, tables, quotes, links, images, math, rules).
Not a server, not a reader, not configurable. Not fast, not polished, not the final
shape of any of these files. It is small enough to read end to end in one sitting and
sturdy enough that every later feature is an addition to a pattern already proven here,
not a new pattern.

The full backlog — everything named but not built — lives in `dev/terms.md`.

## Where the old work went

The 21 design notes and full reference docs from the 0.1.x line are not lost — they
live on `slopbox` (and `origin/slopbox`) and on `main`. They're worth reading before
re-deciding something they already settled, but they don't govern these branches.

## Process

Same as before: the human decides language syntax, the AI drafts and implements. See
`dev/journal.md` for the running record of sessions.
