# Strike reader — UI philosophy

The principles behind the reader's chrome (`src/shell.zig` + the generated pages in
`src/site.zig`). Design decisions here bind future UI work the way CLAUDE.md's
architecture invariants bind the code.

## Content is sovereign

- **`main.sx`/`main.md` dictates its page entirely.** At the content root it *is* the
  picker page; at a project root it is the home; in a subfolder it is the folder page.
  The reader never appends generated furniture (grids, cards, lists) after author
  content — if a `main.*` exists, what the author wrote is the whole page.
- **Generated defaults are minimal.** In the absence of a `main.*`, a page is a heading
  and a plain list of links. Nothing more.
- **Chrome never styles content.** The seasonal themes color the reader — sidebar,
  page background, controls. Document typography belongs to strikedown (directives,
  `.sxh` headers), never to reader settings.

## Links are text

Every navigation affordance is a plain clickable text link. No bubbles, cards, tiles,
icons, or hover-lift animations. If a link needs prominence, the author gives it
prominence in `main.*`.

## The sidebar is minimal

- **The sidebar owns navigation.** Within a project it's the doc tree; on the root
  homepage it lists the projects — so every page is reachable from the sidebar no
  matter what the author put in `main.*`.
- Navigation first: brand, nav tree, and (at the bottom) the settings triggers.
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

| Season | Morning | Evening |
| --- | --- | --- |
| fall | off-white / beige / brown, light-orange accent | dark green, olive accent |
| winter | white / light blue | dark navy, blueish white |
| spring | light pink / lavender | dark grey, green accent |
| summer | light green, purple accent | dark maroon / black |

Palette tokens (7 CSS variables per variant) live in `src/shell.zig`; the yaml `theme:`
key supplies a site default (`winter evening`, `dark`, `spring`, …) that readers
override in Settings.

## Small and self-contained

- All CSS/JS is inline string constants in `shell.zig`; no framework, no build step,
  no external assets beyond MathJax.
- Reader state (season, time, width, font size, line height, font, sidebar, nav
  folders) persists in `localStorage` only, restored pre-paint by the head bootstrap
  so pages never flash.
- Generated HTML stays small and readable; prefer deleting chrome to adding it.
