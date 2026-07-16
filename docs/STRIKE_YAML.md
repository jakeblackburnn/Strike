# `strike.yaml`

`strike.yaml` is the optional config that controls how `strikedown/` is organized into
**projects** and how each project's sidebar nav is labelled and ordered. It is parsed once
at startup by `src/yaml.zig` — **restart the server to pick up changes** (or run
`strike serve --watch`, which re-scans content *and* config on change).

Everything is optional. With no `strike.yaml` anywhere, the site still works: projects are
the top-level folders (alphabetical), docs auto-discover, and labels fall back to each
doc's first heading (then a prettified filename).

## Scopes

There are two scopes, each a separate file.

### Site — `strikedown/strike.yaml`

Controls the whole site: the `/` project picker and global defaults.

```yaml
title: strikedown   # picker heading + browser title base
repo: https://github.com/you/strike   # default sidebar repo-link for every page
theme: winter evening  # default theme: a season (fall|winter|spring|summer), a time
                    # (morning|evening), or both; light/dark are aliases for
                    # morning/evening. Readers can still override in Settings.
width: 44           # default content width, in rem
base: /docs         # mount the site under a subpath of an existing website (see below)
header: theme.sxh   # typography header applied to every project's documents (see below)
projects:           # project order on the picker + nav; unlisted ones sort alphabetically after
  - data_mining
  - pchem
serve:              # default options for `strike serve <this dir>` (see below)
  watch: true
  open: true
```

#### `serve` — default reader options

The `serve:` map fills in any `strike serve` option the command line left unset, so a
site can declare its preferred reading setup (`strike serve strikedown` behaving like
`--watch --open`) with no flags. Keys: `watch`, `open` (booleans), `host`, `port`.
**Explicit flags always win** — including the negations `--no-watch` / `--no-open` for
overriding a yaml `true`. Only directory targets read it; serving a single file uses
flags and built-in defaults. Malformed values (e.g. a non-numeric `port`) are ignored,
fail-soft like everything else here.

#### `base` — mounting under a subpath

Set `base:` when the site lives under a subpath of an existing website (e.g.
`yoursite.com/docs/`) rather than at a domain root. Every generated link then carries the
prefix (`/docs`, `/docs/pchem/quantum`, …), and `strike serve` answers under it too, so the
local preview mirrors production exactly. The **static export stays mount-point-relative**
(`index.html`, `pchem/quantum.html`, …) — deploy the output directory *at* the base (e.g.
`webroot/docs/`), don't nest it again. `docs`, `/docs`, and `docs/` all mean the same
thing; multi-segment bases (`/help/v2`) work. Without `base:` everything behaves as before
(links from `/`).

### Per-project — `strikedown/<project>/strike.yaml`

Controls one project's display metadata and its sidebar nav.

```yaml
title: Data Mining                       # display name (else the prettified folder name)
description: CSCI 436/536 — course notes  # shown on the generated project home
repo: https://github.com/you/dm          # per-project repo link (overrides the site repo)
home: FINAL_REVIEW_GUIDE.md              # doc served at /<project> (else a generated index)
header: theme.sxh                        # project typography header, layered over the site one

labels:                                  # project-relative path → sidebar label
  01_probability_statistics.md: Probability & Statistics
  topo: Topology                         # folders get labels too
  topo/algo_ref: Algorithm Reference
  topo/topology.md: Lesson 1 — Continuity

order:                                   # sorts each directory; unlisted siblings follow alphabetically
  - FINAL_REVIEW_GUIDE.md
  - 01_probability_statistics.md
  - topo

hidden:                                  # excluded from the nav AND from routes (404)
  - PRACTICE_EXAM.md
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
- **In a subfolder** (`.../topo/main.md`): the folder gains its own page at
  `/<project>/topo`, and its sidebar label becomes a link. Folders without a `main.*`
  have no page (unchanged).
- **At the content root, in picker mode**: its content replaces the picker's default
  site-title heading (the project grid still follows). It does *not* create a root
  project by itself. If loose docs already make a root project, `main.*` is simply that
  project's home at `/`.

`main.sx` beats `main.md` when both exist in one directory.

### Typography headers — `.sxh` (reserved)

`strike.yaml` configures the *reader* (nav, ordering, mounting); typography belongs to
strikedown itself, as **`:` directive lines**. A `.sxh` header file is a shared
collection of such directives that `header:` attaches to a whole scope. The directive
namespace is currently **reserved** — no `:` directive is defined, so `.sxh` contents
are inert and every in-document `:` line is ordinary prose (see `docs/STRIKEDOWN.md`).
The plumbing works and stays: `header:` paths are relative to the file's own directory
(content root for the site scope, the project folder for a project); a project header
layers over the site header. `.sxh` files are never documents — they don't appear in
nav or routes. A missing/unreadable header prints a warning and is ignored.

## Key reference

| Key | Scope | Effect |
| --- | --- | --- |
| `title` | site / project | Picker/browser title (site); project display name (project) |
| `repo` | site / project | Sidebar repo-link URL; project value overrides site |
| `theme` | site | Default season (`fall`/`winter`/`spring`/`summer`) and/or time (`morning`/`evening`; `light`/`dark` alias) before the reader picks |
| `width` | site | Default content width in rem |
| `base` | site | Subpath the site is mounted under (`/docs`); links + serve routes carry it, export paths don't |
| `projects` | site | Explicit project order on the picker + nav |
| `serve` | site | Default `strike serve` options (`watch`, `open`, `host`, `port`); flags win |
| `description` | project | Generated project-home subtitle |
| `home` | project | Project-relative doc served at `/<project>` (else the project's `main.*`, else a generated index) |
| `header` | site / project | Typography header (`.sxh`) seeding every document in the scope; project layers over site |
| `labels` | project | Path → nav label, for files **and** folders |
| `order` | project | Per-directory ordering of files/folders |
| `hidden` | project | Paths dropped from nav + routes |

Paths in `labels`, `order`, and `hidden` are **project-relative** (e.g. `topo/algo_ref`),
use forward slashes, and include the file extension for documents.

## How values resolve

- **Label** for a nav entry: `labels:` entry → the doc's first heading → prettified filename
  (drops a leading `NN_` prefix, swaps `_`/`-` for spaces, Title-Cases).
- **Ordering**: within each directory, children listed in `order:` come first (in that
  order); everything else follows alphabetically by path.
- **Theme / width defaults**: spliced into the no-flash bootstrap as the fallback used only
  when the reader has no saved preference — they never override a reader's choice.
- **Self-contained projects**: a project's sidebar only shows that project. `/` is the single
  place to cross between projects (a picker) — unless a root project exists, in which case
  `/` is its home instead and there's no automatic cross-project page (see "Root project"
  above). The brand link always returns to `/`.

## Supported YAML

Deliberately a **small subset** (no external YAML dependency — see `src/yaml.zig`):

- `# comments` (whole-line or trailing) and blank lines
- `key: value` scalars — bare, `"double"`-, or `'single'`-quoted
- nested maps via indentation
- block sequences (`- item`) of scalars and of maps

**Not** supported: flow collections (`[a, b]`, `{a: b}`), anchors/aliases (`&`/`*`), block
scalars (`|`, `>`), tags, and multi-document streams. A malformed or unreadable file is
ignored (the project falls back to defaults) rather than crashing the server.
