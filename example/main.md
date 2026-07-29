# strikedown by example

This folder is a working strikedown site. `zig build run` serves it; every page
here exercises features you can copy into your own documents.

It is also the fastest way to see what the language does: read a page in your
browser, then open the same file in your editor and compare.

// tour grid(2)

**Start here**

. [The markdown subset](markdown.md) — everything plain markdown gives you
. [Layout & commands](layout.md) — the superset: groups, grids, widths, color
. [Degradation](degradation.md) — why plain markdown never breaks

// --

**Then**

. [Guide](guide/main.md) — a folder with its own page
. [Cross-document links](guide/cross-links.md) — linking between files
. `strike.yaml` in this folder — nav labels, order, theme, serve defaults

// end tour

## What this is

- **strikedown** (`.sx`) is the language: a typography-first superset of
  markdown. Plain markdown is a subset of it, so a `.md` file and a `.sx` file
  parse identically.
- **strike** is the toolkit: this reader, a static exporter, and a renderer.

  Everything a document says about its own layout is written in the document.
  Everything about *navigating* documents lives in `strike.yaml`.

## Try it

```sh
strike serve example --watch   # this site, live-reloading as you edit
strike render example/main.md  # one file to HTML on stdout
strike build example -o html   # the whole site as static HTML
```

> [!TIP]
> With `--watch` running, edit any file in this folder and the browser reloads
> itself. The `serve: watch: true` line in `strike.yaml` turns that on by
> default, so plain `strike serve example` watches too.
