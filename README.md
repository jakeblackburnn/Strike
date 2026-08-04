# strike

- strikedown (.sx): sexy superset of markdown 
- strike: cli tool & md/sx->html renderer & sx/md reader (local web server w/ live reload)

## motivation

This tool is meant to be a solution to the limitations of markdown, not just in terms of typographic features, 
but also the lack of a super usable way to read md files and organize them into projects. 

Strikedown itself is the superset of markdown with additional features (more styling and layout options)
The point of strikedown is to be able to yield better typographic flexibility in rendering documents 
than what markdown offers, 
while maintaining the simplicity of just editing text files. 

Strike is the official cli toolkit for using strike, and should be used as a reader for markdown / strikedown 
(e.g., writing a file locally and watching the rendering in real time, 
or just reading an existing document) 
as well as a renderer to generate html from md or sx files 
such that one can easily publish documents to a website 
and hopefully, as the project develops, even make printable, professional looking pdfs and such from sx & md.

Mainly the inspiration for this project is a desire to write my notes in vim and immediately read them 
and to easily publish them to the web. 
Hopefully one day I'll be writing my notes, weblog posts, and even my CV all in sx.

Zig is the language of choice here because its cool and I want more stuff to be written in zig.

> [!IMPORTANT] 
> the codebase for strike is mostly AI generated. 
> (mainly sonnet 5, opus 5, and fable). If this is disagreeable to you, send patches. 
> I want this project to be good and to develop more so pls contribute if youre interested. 

## version 1.0.0 
the first minor version (0.1.0) is intended as proof of concept, but is written by AI and so not meant to be 
a fully awesome version of the project - more for nailing down design decisions. 
because I want version 1.0.0 to be human-directed, it will take longer, but probably be better for 
long term quality. going from 0.1.0 to 1.0.0 will be a long arduous rewrite / refactor 
and introduce the full core set of features (tbd) I want for strikedown and strike.

## details

> [!WARNING] 
> the following is AI generated.

### strike

A from-scratch strikedown/markdown parser, HTML renderer, HTTP server, and CLI, written in
Zig — no build-time dependencies beyond the Zig standard library. The one runtime exception
is client-side MathJax (loaded from a CDN), which typesets the LaTeX math the renderer
passes through.

Rendering is two-stage: source parses into a document tree, and backends emit from it
(HTML today; PDF is the planned second backend). `.md` and `.sx` go through the same
pipeline — markdown is strikedown's subset, and superset features are additive: syntax
that means nothing in plain markdown stays plain text until you activate it. The first
layout features are **groups** and **commands**:

```
// two_lists grid(2)

1. left column
2. of a grid

// --

1. right
2. column

// end two_lists

/skinny(50%)

and this one paragraph renders at half the body width, centered
```

A `//` line brackets content into a group whose commands arrange it; a `/command()` line
applies one command to just the next element. Any such line that doesn't parse cleanly is
ordinary prose — plain markdown is never reinterpreted.

The commands so far:

| command | effect |
| --- | --- |
| `grid(n)` | arrange the group's sections in n columns |
| `skinny(N%)` | render at N% of the body column's width, centered (`skinny()` = 75%) |
| `wide(N%)` | the mirror of `skinny`, bleeding evenly into both margins (`wide()` = 125%) |
| `center()` | center-align the contained text |
| `color(role)` | set the contained text to a theme role — `accent`, `muted`, or `fg` |
| `collapse()` / `collapse(open)` | fold the group behind its first element |
| `indent(n)` | inset by n typographic steps; leading whitespace on a paragraph is sugar for one |
| `citations()` | declare the group's numbered list as the document's bibliography |

Documentation:

| | |
| --- | --- |
| [`docs/reference/STRIKEDOWN.md`](docs/reference/STRIKEDOWN.md) | the language spec — the document of record |
| [`docs/reference/MODEL.md`](docs/reference/MODEL.md) | the internal model: tree, pipeline, terminology |
| [`docs/reference/STRIKE_YAML.md`](docs/reference/STRIKE_YAML.md) | the `strike.yaml` reference |
| [`docs/reference/DESIGN.md`](docs/reference/DESIGN.md) | how language changes get decided |
| [`docs/reference/design/`](docs/reference/design) | one note per feature — the candidates, and the decision |
| [`docs/reference/UI.md`](docs/reference/UI.md) | reader UI principles |

## Build

Requires Zig 0.16.0.

```sh
zig build          # build zig-out/bin/strike
zig build run      # build + serve docs/ at http://127.0.0.1:8080 (watching, per its strike.yaml)
zig build test     # run unit tests
```

The build only compiles the CLI — rendering content to HTML is `strike build`'s job (see
below). `zig build run` serves the committed [`docs/`](docs) folder, which is itself a
strike site: two projects behind a picker at `/`, the
[reference docs](docs/reference/main.md) and an [example tour](docs/example/main.sx) that
exercises every language feature. Pass your own target after `--`:

```sh
zig build run -- serve ~/notes --watch
```

## The `strike` CLI

Once built, `zig-out/bin/strike` works against any content directory, not just this repo's
own `docs/`:

```sh
strike serve  [dir|file] [--host HOST] [--port PORT] [--[no-]watch] [--[no-]open]
                                                  # serve a content dir (or one .md/.sx file) over HTTP;
                                                  # --watch re-renders on change + auto-reloads the browser;
                                                  # --open opens the front page in your default browser
strike render <file> [-o out.html] [--fragment] [--header f.sxh]
                                                  # render a single .md/.sx file to HTML
strike build  [dir] [-o outdir]                   # export a content directory to static HTML
strike init   [dir] [--site]                      # scaffold a starter strike.yaml
```

A content directory is organized into **projects** — each top-level folder is a project,
and its `.md`/`.sx` files (recursively, through subfolders) are its documents. Loose docs
directly in the content root form an implicit root project served at `/`. Configure nav
labels, ordering, and metadata with an optional `strike.yaml`; a file named
`main.md`/`main.sx` supplies the content shown at its containing folder's own route (the
content root, a project home, or a subfolder page). To mount the site under a subpath of
an existing website (e.g. `yoursite.com/docs/`), set `base: /docs` in the site
`strike.yaml` — links and the local preview carry the prefix, while the static export
stays relative so you deploy it straight into the mount directory.

`strike build` writes `.html` files but links between them **extensionlessly** (`/guide`,
not `/guide.html`), matching the routes `strike serve` uses. That is what GitHub Pages,
Netlify, and Cloudflare Pages serve out of the box. A host that doesn't try `.html`
itself — bare nginx, or opening the export over `file://` — needs to be told to; for
nginx that is one line:

```nginx
try_files $uri $uri.html $uri/index.html =404;
```

The renderer covers a practical GFM subset: headings with anchor ids, pipe tables, nested
and task lists, images, autolinks, strikethrough, backslash escapes, fenced code with
`language-*` classes, blockquotes (including `> [!NOTE]`-style alerts), and LaTeX math
delimiters (typeset client-side by MathJax).

Emphasis follows CommonMark's flanking rules, so `a * b * c` and `5 * 4 * 3` keep their
literal asterisks; `$5 and $10` is not math for the same reason.

On top of that, strikedown adds groups and the commands above (as `//` group directives
and single-command `/cmd()` lines), `[text].color(role)` inline spans,
`[text].cite(refs)` citation marks that bind to a `citations()` bibliography, undecorated
`.` lists, whitespace-indented paragraphs, and cross-document links — a relative
`.md`/`.sx` target resolves to the sibling document's route when a site is being rendered
(`serve` and `build`); `strike render`, which knows one file and no site, leaves such a
target exactly as written. Every one of these degrades to inert prose in a document that never
activates it, which is why plain markdown renders unchanged. The spec is
[`docs/reference/STRIKEDOWN.md`](docs/reference/STRIKEDOWN.md).

One thing the renderer deliberately does not do is filter link schemes. URLs are escaped,
never vetted, so a `javascript:` target in a document renders as written. The threat model
here is "you are reading your own writing" — and any allowlist immediately has to rule on
`data:`, `tel:`, `obsidian://` and the rest, which is a language decision wanting its own
design note rather than a quiet default. Don't point strike at documents you wouldn't run.

## License

MIT — see [`LICENSE`](LICENSE).
