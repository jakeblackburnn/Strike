# `strike.yaml`

`strike.yaml` is the optional config that controls how a content directory is organized
into **projects** and how each project's sidebar nav is labelled and ordered. It is parsed
once at startup by `src/yaml.zig` — **restart the server to pick up changes**, or run
`strike serve --watch`, which re-scans content and config together.

The one exception is `serve:` itself, which is resolved before the server starts: editing
it under `--watch` has no effect until the next `strike serve`.

Examples below use `docs/` as the content directory, the same one this site is built from.

Everything is optional. With no `strike.yaml` anywhere, the site still works: projects are
the top-level folders that hold at least one `.md`/`.sx` file, recursively (alphabetical;
a folder with none, like `images/`, is skipped as a project but its files are still
served), docs auto-discover, and labels fall back to each doc's first heading (then a
prettified filename).

## Scopes

There are two scopes, each a separate file.

### Site — `docs/strike.yaml`

Controls the whole site: the `/` project picker and global defaults.

```yaml
title: strikedown   # picker heading + browser title base
theme: winter evening  # default palette (including kanagawa/vanta-black) and a time
                    # (morning|evening), or both; light/dark are aliases for
                    # morning/evening. Readers can still override in Settings.
width: 46           # default content width, in rem
sidebar_width: max  # default sidebar width: bare rem, or min/max
base: /docs         # mount the site under a subpath of an existing website (see below)
root: https://example.com       # external parent site; only honored alongside base:
root_label: Example             # else the root: URL's host
header: theme.sxh   # typography header applied to every project's documents (see below)
projects:           # project order on the picker + nav; unlisted ones sort alphabetically after
  - example
  - reference
serve:              # default options for `strike serve <this dir>` (see below)
  watch: true
  open: true
pdf:                # defaults for `strike pdf` on files in this tree
  page_size: a4
  margin: 54pt
nav:                # sidebar/brand defaults — all optional, shown here at
  scope: full       # their own defaults (see below)
  open: true
  breadcrumb: true
```

#### `nav` — sidebar scope, folder disclosure, breadcrumb

Site-scope only — nav shape is one whole-site property, so there is no per-project
override (a reader crossing between projects shouldn't see the sidebar change rules).

- `scope: full` (default) — every page's sidebar carries the whole site: every
  project and its documents, the same tree the picker has always shown, not just the
  page's own project. `scope: project` restores the pre-`nav:` behavior — a project's
  sidebar shows only that project's tree, and crossing to another project goes through
  the front page.
- `open: true` (default) — nav folders render expanded (`<details open>`); a reader's
  own collapse (saved in Settings/`localStorage`) still wins over this default. `open:
  false` restores the old behavior: a folder starts closed unless it's an ancestor of
  the page you're on.
- `breadcrumb: true` (default) — the sidebar brand is a **two-segment** breadcrumb,
  capped, each segment its own line — no wrapping, no `/` between them: the site root on
  top (**root is always root** — it always reaches `/` or the mount base, however deep
  the page sits), then at most one more line underneath for the nearest thing below
  root — the project (outside root-project mode), or the page's nearest ancestor nav
  folder, whichever is closer. Anything past that single line — a project *and*
  folders, or several nested folders — collapses into it: its label gains a `..` prefix
  (`..design`, no separator), and it still links to that nearest folder's `main.*` when
  it has one, plain text otherwise. `docs/a/b/c.md` shows `docs`, then `..b` (not `docs`
  / `a` / `b` / `c`, one per line); `docs/a/c.md` (one folder) shows the uncompressed
  `docs`, then `a`. `breadcrumb: false` drops the second line down to just the project
  (site, then project — nothing about the page's own folder).

Each key falls back to its default on a garbage value (`scope: sideways`), same as
every other yaml key here — fail-soft, never a crash.

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

#### `root` — linking out to a parent site

`root:` sends the sidebar brand's root segment to an external site instead of this
site's own `/` — for a site mounted as a subroute of a bigger personal site (`base:
/weblog` under `jake.example`, say), where the reader's fastest click home should reach
`jake.example`, not `jake.example/weblog`. It's only honored alongside `base:` (an
external root link makes sense only for a site that *is* a subroute of something else)
and only when it's either an `http://`/`https://` URL or a local absolute path
(`/site-content`, say — for a dev server that shouldn't link out to the live domain
while testing) — otherwise ignored, same fail-soft rule as every other key here. A local
path additionally requires `root_label:` (there's no host to derive a default label
from); an unlabeled local path is ignored like any other malformed value.

Setting it doesn't strand the local site: it adds a second, always-present brand
segment underneath — this site's own `base:` path, linking to its own `/` (or mount
base) — and, on any page below that front page, a third segment for the current page's
nearest project/folder (the same "nearest thing below root" compression `nav:
{breadcrumb: true}` uses, above, but appended rather than replacing the fixed segments,
and prefixed with a literal `/`). The root segment renders bold; the base and folder
segments don't — so the brand reads as up to three lines, `root:`'s target on top and
bold, the local front page and current folder underneath it in the reader's normal
weight.

`root_label:` names the first segment; unset, it defaults to the `root:` URL's host
(`https://jake.example` → `jake.example`) when `root:` is a URL, and is required (see
above) when `root:` is a local path.

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

### Typography headers — `.sxh`

`strike.yaml` configures the reader (nav, ordering, mounting); a `.sxh` header
sets document typography and reusable command aliases. Typography lines are
`font: serif|sans|mono`, `measure: Nrem` (0.5–120), `size: Nrem` (0.5–5), and
`leading: N` (1–3). An alias line uses the existing `:` directive form, such as
`:thin-grid grid(2) skinny(80%)` (`docs/reference/design/010-aliases.md`).
See [the live header](../paper/paper.sxh) and its [report](../paper/paper.sx).
`header:` paths are relative to the
file's own directory (content root for the site scope, the project folder for a
project); a project header layers over the site header — an alias the project redefines
overrides the site's same-named one; each typography field also layers separately.
Malformed or unknown lines are ignored. `.sxh` files are never documents — they don't
appear in nav or routes. A missing/unreadable header prints a warning and is ignored.

### Theme files

`theme_file: paper.theme` loads a fixed palette beside that `strike.yaml`.
The file needs a `label:` and all 13 palette declarations (`color-scheme` and
the twelve CSS color/shadow properties shown in
[paper.theme](../paper/paper.theme)). Strike validates the values and inlines
the resulting CSS at build time. The reader offers the file's label as the
**Custom** theme. Set `theme: custom` to select it by default; a project file
overrides a site file. No runtime theme fetch is needed.

## Key reference

| Key | Scope | Effect |
| --- | --- | --- |
| `title` | site / project | Picker/browser title (site); project display name (project) |
| `theme` | site / project | Default palette (`fall`, `winter`, `spring`, `summer`, `kanagawa`, `vanta-black`, or `custom` with `theme_file`) and/or time (`morning`/`evening`; `light`/`dark` alias); project values override by field |
| `theme_file` | site / project | Dir-relative fixed palette file, inlined into HTML and selectable as Custom |
| `width` | site / project | Default content width in rem; an `.sxh` measure takes precedence |
| `sidebar_width` | site / project | Default sidebar width: a bare rem number (clamped to the reader's `−`/`+` range if it overshoots) or `min`/`max` for that range's floor/ceiling |
| `base` | site | Subpath the site is mounted under (`/docs`); links + serve routes carry it, export paths don't |
| `root` | site | An external parent site's homepage (or, for dev, a local path) the brand's root segment links to instead of this site's own `/`; ignored unless `base:` is also set and the value is an `http(s)://` URL or a local absolute path |
| `root_label` | site | Label for the `root:` segment; defaults to the URL's host for an `http(s)://` value, required for a local-path value |
| `projects` | site | Explicit project order on the picker + nav |
| `serve` | served dir | Default `strike serve` options (`watch`, `open`, `host`, `port`); flags win; not re-read by `--watch` |
| `pdf` | site / project | PDF page size (`letter` or `a4`) and margin (points or inches); nearer config and CLI flags win |
| `nav` | site | Sidebar `scope` (`full`/`project`), folder `open` default, brand `breadcrumb` on/off |
| `description` | project | Generated project-home subtitle |
| `home` | project | Project-relative doc served at `/<project>` (else the project's `main.*`, else a generated index) |
| `header` | site / project | Typography header (`.sxh`) seeding every document in the scope; project layers over site |
| `labels` | project | Path → nav label, for files **and** folders |
| `order` | project | Per-directory ordering of files/folders |
| `hidden` | project | Paths dropped from nav + routes |

Paths in `labels`, `order`, and `hidden` are **project-relative** (e.g. `topo/algo_ref`),
use forward slashes, and include the file extension for documents.

## Not configurable

The sidebar brand's *subtitle* (the small strike attribution link beneath it) is chrome,
not config — no yaml key sets it, and there is no per-site repo link. `docs/reference/UI.md`
says why and what to do instead. The brand's root segment itself *is* configurable — see
`root:` above and "Root is always root, unless mounted under a parent site" below.

## How values resolve

- **Label** for a nav entry: `labels:` entry → the doc's first heading → prettified filename
  (drops a leading `NN_` prefix, swaps `_`/`-` for spaces, Title-Cases).
- **Ordering**: within each directory, children listed in `order:` come first (in that
  order); everything else follows alphabetically by path.
- **Theme / width defaults**: spliced into the no-flash bootstrap as the fallback used only
  when the reader has no saved preference — they never override a reader's choice, and
  nothing in the reader may overwrite them for a reader who has expressed none
  (`docs/reference/UI.md`, "The reader-state contract").
- **Full-site nav, by default**: every page's sidebar carries the whole site — the same
  tree the picker has always shown, every project expandable into its own documents — not
  just the page's own project, so any document is one click away from any other. `nav:
  {scope: project}` restores the older behavior: a project's sidebar shows only that
  project's tree, and crossing between projects goes through `/`. (A root project has no
  picker: `/` is its home either way — see "Root project" above.)
- **Root is always root, unless mounted under a parent site**: the sidebar brand's first
  segment always reaches `/` (or the mount base), however deep the page sits, then at
  most one more segment for the nearest thing below root — the project (outside
  root-project mode) or the page's nearest ancestor folder — `..`-compressed when
  there's more than one level between root and the page. `nav: {breadcrumb: false}`
  drops that second segment down to just the project. When `root:` is set, this whole
  scheme is replaced by two fixed segments — `root:`'s target first (bold), then this
  site's own `/` (or mount base) — plus a third, optional segment on any page below that
  front page, for the current page's nearest project/folder (`/`-prefixed, same
  compression as above). A site living under a parent site's subroute (e.g.
  `jake.example/weblog`) can send readers to the parent's homepage without losing a
  one-click way back to its own front page, or "where am I" on a deep page.

## Supported YAML

Deliberately a **small subset** (no external YAML dependency — see `src/yaml.zig`):

- `# comments` (whole-line or trailing) and blank lines
- `key: value` scalars — bare, `"double"`-, or `'single'`-quoted
- nested maps via indentation
- block sequences (`- item`) of scalars and of maps

**Not** supported: flow collections (`[a, b]`, `{a: b}`), anchors/aliases (`&`/`*`), block
scalars (`|`, `>`), tags, and multi-document streams. A malformed or unreadable file is
ignored (the project falls back to defaults) rather than crashing the server.
