# strike (base_md)

`strike` is a from-scratch markdown/strikedown parser, HTML renderer, and CLI, written
in Zig with no dependencies beyond the standard library.

This branch, `base_md`, is a deliberate restart: the smallest possible spine of the
toolkit, markdown only. It is not feature-complete markdown and does not try to be —
see `dev/intent.md` for why these base branches exist, and `dev/terms.md` for exactly
what is and isn't implemented (the backlog list is long and on purpose).

A sibling branch, `base_sx`, is this same code plus the smallest possible strikedown
superset feature (groups). The AI-written 0.1.x proof of concept this restarts lives on
`slopbox`/`main`.

## What's here at v0.0.1

- Headings, paragraphs, fenced code blocks.
- Inline code, `**strong**`, `*em*` (nestable).
- `strike render <file> [-o out.html] [--fragment]` — the only subcommand.

## Build

Requires Zig 0.16.0.

```sh
zig build test              # unit + end-to-end tests
zig build run                # renders sample/kitchen-sink.md to stdout
zig build && zig-out/bin/strike render sample/hello.md
```

## Layout

- `src/doc.zig` — the document model (`Doc`, `Block`, `Inline`). No I/O.
- `src/parse.zig` — source → `Doc`. Pure; the block loop + inline chain.
- `src/emit_html.zig` — `Doc` → HTML.
- `src/html.zig` — text/attribute escaping.
- `src/main.zig` — the CLI.
- `dev/` — project memory: `intent.md` (why), `terms.md` (vocabulary + design
  decisions + backlog), `journal.md` (session log).
- `sample/` — small example documents.
