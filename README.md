# strike (base_sx)

`strike` is a from-scratch markdown/strikedown parser, HTML renderer, and CLI, written
in Zig with no dependencies beyond the standard library.

This branch, `base_sx`, is `base_md`'s minimal toolkit spine plus the smallest possible
strikedown superset feature: groups. It is not feature-complete strikedown and does not
try to be — see `dev/intent.md` for why these base branches exist, and `dev/terms.md`
for exactly what is and isn't implemented (the backlog list is long and on purpose).

`base_md` (this branch's parent commit) is the markdown-only spine with no superset
features at all. The AI-written 0.1.x proof of concept both restart lives on
`slopbox`/`main`.

## What's here at v0.0.1

- Everything in `base_md`: headings, paragraphs, fenced code; inline code, `**strong**`,
  `*em*`.
- **Groups**, the one strikedown feature: `// name` opens a named container,
  `===` splits it into sections, `// end name` closes it. No commands, no styling —
  see `sample/groups.sx`.
- `strike render <file> [-o out.html] [--fragment]` — the only subcommand. `.md` and
  `.sx` go through the identical parser and emitter; nothing branches on extension.

## Build

Requires Zig 0.16.0.

```sh
zig build test              # unit + end-to-end tests
zig build run                # renders sample/kitchen-sink.md to stdout
zig build && zig-out/bin/strike render sample/groups.sx
```

## Layout

- `src/doc.zig` — the document model (`Doc`, `Block`, `Group`, `Inline`). No I/O.
- `src/parse.zig` — source → `Doc`. Pure; the recursive block loop (groups nest via the
  call stack) + inline chain.
- `src/emit_html.zig` — `Doc` → HTML.
- `src/html.zig` — text/attribute escaping.
- `src/main.zig` — the CLI.
- `dev/` — project memory: `intent.md` (why), `terms.md` (vocabulary + design
  decisions + backlog), `journal.md` (session log).
- `sample/` — small example documents, including `groups.sx`.
