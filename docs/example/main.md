# strikedown by example

Every page in this project exercises features you can copy into your own
documents. It is the fastest way to see what the language does: read a page in
your browser, then open the same file in your editor and compare.

// tour grid(2)

**Start here**

. [The markdown subset](markdown.md) — everything plain markdown gives you
. [One flavor](syntax.sx) — a `.sx` file, to show it parses like a `.md` one
. [Layout & commands](layout.md) — the superset: groups, grids, widths, color
. [Degradation](degradation.md) — why plain markdown never breaks

// --

**Then**

. [Guide](guide/main.md) — a folder with its own page
. [Cross-document links](guide/cross-links.md) — linking between files
. `strike.yaml` in this folder — this project's nav labels and order

// end tour

## What this is

- **strikedown** (`.sx`) is the language: a typography-first superset of
  markdown. Plain markdown is a subset of it, so a `.md` file and a `.sx` file
  parse identically.
- **strike** is the toolkit: this reader, a static exporter, and a renderer.

  Everything a document says about its own layout is written in the document.
  Everything about *navigating* documents lives in `strike.yaml`.

## Where this sits

This project is one half of the site you are reading. Its parent folder,
`docs/`, is the content root: it holds only folders, so `/` is a **project
picker** with this tour on one side and the [reference docs](../reference/main.md)
on the other. Site-wide settings — theme, default width, serve defaults — live
in `docs/strike.yaml`; this folder's own `strike.yaml` carries only what shapes
this project's nav.

## Try it

```sh
strike serve docs --watch          # the whole site, live-reloading as you edit
strike serve docs/example          # just this project, as a site of its own
strike render docs/example/main.md # one file to HTML on stdout
strike build docs -o html          # the whole site as static HTML
```

> [!TIP]
> With `--watch` running, edit any file under `docs/` and the browser reloads
> itself. The `serve: watch: true` line in `docs/strike.yaml` turns that on by
> default, so plain `strike serve docs` watches too.

  Serving this folder directly is worth trying: with loose documents at the
  content root and no folder to pick from, strike drops the picker and treats
  the whole tree as one **root project** at `/`. Same files, same output, one
  less level of navigation.
