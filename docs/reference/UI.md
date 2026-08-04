# Strike reader — UI philosophy

The principles behind the reader's chrome (`src/shell.zig` + the generated pages in
`src/site.zig`). Decisions here bind future UI work the way `docs/reference/STRIKEDOWN.md` binds
the language: where habit or a passing preference disagrees with this file, this file
wins.

## Content is sovereign

- **`main.*` dictates its page entirely.** The reader never appends generated furniture
  (grids, cards, lists) after author content — if a `main.*` exists, what the author
  wrote is the whole page. (Which route each `main.*` claims is a config question:
  `STRIKE_YAML.md`.)
- **Generated defaults are minimal.** In the absence of a `main.*`, a page is a heading,
  the project's `description:` if it has one, and a plain list of links. Nothing more.
- **Chrome supplies the palette; it never overrides the author.** The seasonal themes
  define what `accent`, `muted` and `fg` *look like* — and document color roles resolve
  against exactly those tokens, so chrome and content share one palette by design. What
  chrome must never do is override a decision the document made: no reader setting
  competes with a directive. Document typography belongs to strikedown; the reading
  environment belongs to the reader.

## Links are text

Every navigation affordance is a plain clickable text link. No bubbles, cards, tiles,
icons, or hover-lift animations. If a link needs prominence, the author gives it
prominence in `main.*`.

## The sidebar is minimal

- **The sidebar owns navigation.** Within a project it's that project's doc tree; on the
  front page of a multi-project site it's the *whole* site — one expandable node per
  project, each holding that project's tree, so every document is one click from the
  front page rather than two. So on any screen wide enough to show it, every page is
  reachable from the sidebar no matter what the author put in `main.*`. (Narrow screens
  are the standing exception — see "Narrow screens".)
- **A project node is a folder node.** Nothing about a project's row in the front-page
  nav is special: it is the same disclosure control a folder inside a project gets, with
  the same label-links-to-its-page rule and the same persistence. Projects open by
  default there — the front page's job is to show what the site holds.
- Navigation first: brand, nav tree, and (at the bottom) the settings triggers.
- **The brand is a way back, and it is a path.** Inside a project it shows that project's
  title and links to the project's own root — the reader's "up". On a multi-project site
  it leads with the site title, linked to the front page, because the nav below is one
  project's tree and so can never be the way back to it. A project that *is* the whole
  site gets no site segment; naming it twice would only link to the page you are on.
  Under the brand sits the chrome's one outbound link: a small muted subtitle crediting
  strike. All of it is fixed, not configurable; a link to the author's own repo is author
  content and belongs in `main.*`.
- **The right edge is the collapse control.** No arrow buttons: hovering the sidebar
  warms the edge line, hovering the edge itself lights it in the accent color, and
  clicking it toggles. The sidebar slides away; the edge strip slides to the screen's
  left edge and reopens it the same way.
- Collapsed means **gone**: zero width, no reserved margin — only the hairline edge
  strip remains to bring it back.
- Settings stay out of the sidebar body. Two plain-text triggers at the bottom —
  **Theme** and **Text** — each open their own panel that pops out *over* the sidebar
  (opening one closes the other). Theme choices are selectable text links, not
  dropdowns; Text holds reading settings: content width, font size, line height, and
  font family (sans/serif) — these style the reading experience, never the document's
  own typography (that stays in strikedown).

## Seasonal themes

Four themes, each with a light **morning** and dark **evening** variant. They apply to
the reader chrome only. Two orthogonal attributes drive them: `data-season` and
`data-time` on `<html>`; with no explicit time, the system color-scheme preference
decides. Default season: **winter**.

| Season | Morning (light) | Evening (dark) |
| --- | --- | --- |
| fall | warm off-white, brown text, orange accent | deep green, olive accent |
| winter | white, navy text, blue accent | dark navy, pale blue text and accent |
| spring | pale pink, plum text, purple accent | neutral dark grey, pink accent |
| summer | cream, deep green text, green accent | near-black maroon, muted red accent |

Twelve palette tokens per variant live in `src/shell.zig`: `--bg`, `--fg`, `--muted`,
`--accent`, `--warn`, `--code-bg`, `--border`, `--sidebar-bg`, and four
`--collapse-*` tokens for the collapsible-group card. A new theme defines all twelve.
The yaml `theme:` key supplies a site default (`winter evening`, `dark`, `spring`, …)
that readers override in Settings.

## Narrow screens

Below `50rem` the sidebar becomes a plain horizontal strip holding the brand and nothing
else: the nav tree, the settings triggers, and the collapse edge are all hidden. A narrow
reader therefore has **no settings and almost no navigation** — the brand path is all
that survives, which on a multi-project site at least reaches the front page (and from
there its nav, still hidden). Otherwise they read the page they landed on and move by the
links inside it.

This is a real limitation, recorded here rather than papered over: it is why author
content matters more on small screens, and why a project's `main.*` should link onward.
Closing it (a drawer, or a compact nav) is open UI work, and whatever closes it must keep
"the sidebar owns navigation" true on every width.

## Small and self-contained

- All CSS/JS is inline string constants in `shell.zig`; no framework, no build step,
  no external assets beyond MathJax.
- Reader state persists in `localStorage` only, restored pre-paint by the head bootstrap
  so pages never flash.
- Generated HTML stays small and readable; prefer deleting chrome to adding it.

### The reader-state contract

Every key the reader writes, and the `<html>` attribute it drives. Anything reading or
writing reader state uses these names.

| Key | Values | Effect |
| --- | --- | --- |
| `season` | `fall` / `winter` / `spring` / `summer` | `data-season` |
| `time` | `morning` / `evening`, or absent for auto | `data-time`; absent means the system preference decides |
| `width` | a number, in `rem` | `--content-width` |
| `fontsize` | a number, in `px` | `--font-size` |
| `lineheight` | a number, unitless | `--line-height` |
| `font` | `serif`, or absent for sans | `data-font` |
| `sidebar` | `collapsed` / `expanded` | `data-sidebar` |
| `nav:<slug>/<path>` | `open` / `closed` | one nav folder's disclosure state |
| `nav:<slug>` | `open` / `closed` | one *project's* node on the front page (no `/`, so it can't collide with a folder) |

A legacy `theme` key (`light`/`dark`) from before seasons is migrated to a `time` on
first load and then removed.

**A site default is a default, not an override.** The bootstrap seeds the theme and width
from `strike.yaml` *only* where the reader has saved nothing, and no later script may
overwrite what it set — a reader with no preference must keep seeing the site's, and a
reader with one must always win.
