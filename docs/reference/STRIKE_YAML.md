# `strike.yaml`

`strike.yaml` is the optional config that controls how a content directory is organized
into **projects** and how each project's sidebar nav is labelled and ordered. It is parsed
once at startup by `src/yaml.zig` — **restart the server to pick up changes**, or run
`strike serve --watch`, which re-scans content and config together.

The one exception is `serve:` itself, which is resolved before the server starts: editing
it under `--watch` has no effect until the next `strike serve`.

Examples below use `docs/` as the content directory, the same one this site is built from.

Everything is optional. With no `strike.yaml` anywhere, the site still works: projects are
the top-level folders (alphabetical), docs auto-discover, and labels fall back to each
doc's first heading (then a prettified filename).

## Scopes

There are two scopes, each a separate file.

### Site — `docs/strike.yaml`

Controls the whole site: the `/` project picker and global defaults.

```yaml
title: strikedown   # picker heading + browser title base
theme: winter evening  # default theme: a season (fall|winter|spring|summer), a time
                    # (morning|evening), or both; light/dark are aliases for
                    # morning/evening. Readers can still override in Settings.
width: 46           # default content width, in rem
base: /docs         # mount the site under a subpath of an existing website (see below)
header: theme.sxh   # typography header applied to every project's documents (see below)
projects:           # project order on the picker + nav; unlisted ones sort alphabetically after
  - example
  - reference
serve:              # default options for `strike serve <this dir>` (see below)
  watch: true
  open: true
```

#### `serve` — default reader options

The `serve:` map fills in any `strike serve` option the command line left unset, so a
directory can declare its preferred reading setup (`strike serve docs` behaving like
`--watch --open`) with no flags. Keys: `watch`, `open`, `host`, `port`.
**Explicit flags always win** — including the negations `--no-watch` / `--no-open` for
overriding a yaml `true`.

`serve:` is read from **whatever directory you serve**, so a project folder may carry its
own — `strike serve docs/example` honours `docs/example/strike.yaml`'s `serve:`, not the
site's. It is listed as a site key because that is where it usually belongs, not because
the loader looks only there. Serving a single *file* uses flags and built-in defaults
only.

`watch` and `open` are read strictly: the literal `true` enables them and **every other
value, including YAML's `yes` and `on`, means false**. A malformed `port` is ignored.
Fail-soft, like everything else here.

#### `base` — mounting under a subpath

Set `base:` when the site lives under a subpath of an existing website (e.g.
`yoursite.com/docs/`) rather than at a domain root. Every generated link then carries the
prefix (`/docs`, `/docs/example/layout`, …), and `strike serve` answers under it too, so
the local preview mirrors production closely. The **static export stays
mount-point-relative** (`index.html`, `example/layout.html`, …) — deploy the output
directory *at* the base (e.g. `webroot/docs/`), don't nest it again. `docs`, `/docs`, and
`docs/` all mean the same thing; multi-segment bases (`/help/v2`) work. Without `base:`
everything behaves as before (links from `/`).

One known seam: the server's own 404 page links back to `/` rather than to the base, so a
missing route under a mounted preview offers a way out of the mount point.

### Per-project — `docs/<project>/strike.yaml`

Controls one project's display metadata and its sidebar nav.

```yaml
title: strikedown by example             # display name (else the prettified folder name)
description: Every language feature      # shown on the generated project home
home: overview.md                        # doc served at /<project> (else a generated index)
header: theme.sxh                        # project typography header, layered over the site one

labels:                                  # project-relative path → sidebar label
  markdown.md: The markdown subset
  guide: Guide                           # folders get labels too
  guide/cross-links.sx: Cross-document links

order:                                   # sorts each directory; unlisted siblings follow alphabetically
  - markdown.md
  - gallery.sx
  - guide

hidden:                                  # excluded from the nav AND from routes (404)
  - guide/scratch.sx
```

### Root project — loose docs at the content root

If the content root itself has `.md`/`.sx` files directly inside, the *whole tree* forms an
implicit **root project**: it takes over `/` as its own home (its `home:` doc, or a
generated index of its own docs) instead of a cross-project picker — there's nothing to
pick between if the root itself has content — and subdirectories become its nav folders
rather than separate projects. A repo's `docs/` folder therefore serves correctly with no
`strike.yaml` at all. Its own `strike.yaml` is the *same file* as the site-level one above,
since both live at the content root — one file, both scopes, at once. All the per-project
keys below (`labels`, `order`, `hidden`, `home`, `description`, ...) apply to it exactly as
they would to any other project.

The two layouts are exclusive by construction: loose docs at the root ⇒ one root project
owning everything; a root with only subfolders ⇒ one project per subfolder behind the
picker (a root `main.*` alone doesn't tip the balance — see below).

### `main.md` / `main.sx` — content by convention

`strike.yaml` owns *structure* (labels, order, hidden, the `home:` pick); a file named
`main.md`/`main.sx` supplies *content by position*, without changing structure. It never
appears in the sidebar nav and gets no route of its own — instead its rendered content
becomes the page at its containing folder's route:

- **In a project root** (`<content>/<project>/main.md`): the project's home at
  `/<project>`, exactly as if `home: main.md` were set. An explicit `home:` still wins.
- **In a subfolder** (`.../guide/main.sx`): the folder gains its own page at
  `/<project>/guide`, and its sidebar label becomes a link. Folders without a `main.*`
  have no page (unchanged).
- **At the content root, in picker mode**: its content *is* the picker page — it replaces
  the generated site-title heading and project list outright, nothing is appended after
  it. (Navigation doesn't depend on it: the sidebar carries every project and its
  documents regardless.) It does *not* create a root project by itself. If loose docs
  already make a root project, `main.*` is simply that project's home at `/`.

`main.sx` beats `main.md` when both exist in one directory.

### Typography headers — `.sxh` (reserved)

`strike.yaml` configures the *reader* (nav, ordering, mounting); typography belongs to
strikedown itself, as **`:` directive lines**. A `.sxh` header file is a shared
collection of such directives that `header:` attaches to a whole scope. The directive
namespace is currently **reserved** — no `:` directive is defined, so `.sxh` contents
are inert and every in-document `:` line is ordinary prose (see `docs/reference/STRIKEDOWN.md`).
The plumbing works and stays: `header:` paths are relative to the file's own directory
(content root for the site scope, the project folder for a project); a project header
layers over the site header. `.sxh` files are never documents — they don't appear in
nav or routes. A missing/unreadable header prints a warning and is ignored.

## Key reference

| Key | Scope | Effect |
| --- | --- | --- |
| `title` | site / project | Picker/browser title (site); project display name (project) |
| `theme` | site | Default season (`fall`/`winter`/`spring`/`summer`) and/or time (`morning`/`evening`; `light`/`dark` alias) before the reader picks |
| `width` | site | Default content width in rem |
| `base` | site | Subpath the site is mounted under (`/docs`); links + serve routes carry it, export paths don't |
| `projects` | site | Explicit project order on the picker + nav |
| `serve` | served dir | Default `strike serve` options (`watch`, `open`, `host`, `port`); flags win; not re-read by `--watch` |
| `description` | project | Generated project-home subtitle |
| `home` | project | Project-relative doc served at `/<project>` (else the project's `main.*`, else a generated index) |
| `header` | site / project | Typography header (`.sxh`) seeding every document in the scope; project layers over site |
| `labels` | project | Path → nav label, for files **and** folders |
| `order` | project | Per-directory ordering of files/folders |
| `hidden` | project | Paths dropped from nav + routes |

Paths in `labels`, `order`, and `hidden` are **project-relative** (e.g. `topo/algo_ref`),
use forward slashes, and include the file extension for documents.

## Not configurable

The sidebar's brand and its subtitle are chrome, not config — there is no yaml key for
either, and no per-site repo link. `docs/reference/UI.md` says why and what to do instead.

## How values resolve

- **Label** for a nav entry: `labels:` entry → the doc's first heading → prettified filename
  (drops a leading `NN_` prefix, swaps `_`/`-` for spaces, Title-Cases).
- **Ordering**: within each directory, children listed in `order:` come first (in that
  order); everything else follows alphabetically by path.
- **Theme / width defaults**: spliced into the no-flash bootstrap as the fallback used only
  when the reader has no saved preference — they never override a reader's choice, and
  nothing in the reader may overwrite them for a reader who has expressed none
  (`docs/reference/UI.md`, "The reader-state contract").
- **Self-contained projects**: inside a project the sidebar shows only that project, so
  crossing between projects goes through `/` — where the sidebar instead carries the whole
  site, every project expandable into its own documents. From a project page the brand's
  first segment is the way back there. (A root project has no picker: `/` is its home, and
  there's no cross-project page — see "Root project" above.)

## Supported YAML

Deliberately a **small subset** (no external YAML dependency — see `src/yaml.zig`):

- `# comments` (whole-line or trailing) and blank lines
- `key: value` scalars — bare, `"double"`-, or `'single'`-quoted
- nested maps via indentation
- block sequences (`- item`) of scalars and of maps

**Not** supported: flow collections (`[a, b]`, `{a: b}`), anchors/aliases (`&`/`*`), block
scalars (`|`, `>`), tags, and multi-document streams. A malformed or unreadable file is
ignored (the project falls back to defaults) rather than crashing the server.
