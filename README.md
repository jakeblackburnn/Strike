# strike

- strikedown (.sx): sexy superset of markdown 
- strike: cli tool & md/sx->html renderer & sx/md reader (local web server w/ live reload)

## motivation

Hey guy so this tool is meant to be a solution to the limitations of markdown, not just in terms of actual features, 
but also the lack of a super usable way to read md files and organize them into projects. 

Strikedown itself is the superset of markdown with additional features (these actual features are TBD for now). 
The point of strikedown is to be able to yield better typographic flexibility in rendering documents than what markdown offers, 
while maintaining the simplicity of just editing text files. 

Strike is the official cli toolkit for using strike, and should be used as a reader for markdown / strikedown 
(e.g., writing a file locally and watching the rendering in real time, 
or just frictionlessly rendering and reading an existing document) 
as well as a standalone renderer to generate html from md or sx files 
such that one can easily publish documents to a website 
and hopefully, as the project develops, even make printable, professional looking pdfs and such from sx & md.

Mainly the inspiration for this project is a desire to write my notes in vim and immediately read them 
and to easily publish them to the web. (see another project to read my notes as a good intro to what you can expect from strike).
Hopefully one day I'll be writing my notes, weblog posts, and CV in sx.

Zig is the language of choice here because its cool and it probably has a bright future and I want more stuff to be written in zig.

> [!IMPORTANT] 
> the codebase for strike is moslty AI generated. 
> (mainly sonnet 5 and fable). If this is disagreeable to you, send patches. Also, I am new to zig dont bully me. 
> I want this project to be as good as possible and to develop fast so pls contribute if youre interested. 

## details

> [!WARNING] 
> the following is AI generated. yea sry. 



A from-scratch markdown → HTML renderer, HTTP server, and CLI, written in Zig — no
build-time dependencies beyond the Zig standard library. The one runtime exception is
client-side MathJax (loaded from a CDN), which typesets the LaTeX math the renderer passes
through.

`.md` files render today; `.sx` is a planned markdown superset for richer typography (see
`.claude/CLAUDE.md`'s Roadmap section).

## Build

Requires Zig 0.16.0.

```sh
zig build          # build + statically export strikedown/ to zig-out/html/
zig build run      # build + serve strikedown/ at http://127.0.0.1:8080
zig build test     # run unit tests
```

## The `strike` CLI

Once built, `zig-out/bin/strike` works against any content directory, not just this repo's
own `strikedown/`:

```sh
strike serve  [dir|file] [--host HOST] [--port PORT] [--watch]
                                                  # serve a content dir (or one .md/.sx file) over HTTP;
                                                  # --watch re-renders on change + auto-reloads the browser
strike render <file> [-o out.html] [--fragment]   # render a single .md/.sx file to HTML
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

The renderer covers a practical GFM subset: headings with anchor ids, pipe tables, nested
and task lists, images, autolinks, strikethrough, backslash escapes, fenced code with
`language-*` classes, blockquotes, and LaTeX math delimiters (typeset client-side by
MathJax).
