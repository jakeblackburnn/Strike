# Journal · 2026-09-22 16:05 · slopbox · b4e530f
## Start
**State:** Tree committed and clean at `b4e530f` (migrate `dev/` to the journal.md
convention, on `6fd81d8` close-out of v0.2.0). `zig build` clean; `zig build test
--summary all` → 39/39 steps, 1819/1819 tests passed as of the last close-out (stderr
`failed command …--listen=-` on cached test binaries is benign runner noise — read the
summary line, not "failed" text).
**Since:** Nothing yet — this session starts from the close-out.
**Next:**
1. Specify the deferred pagination policy from design note 022 (widow/orphan behavior,
   oversize-block policy, in-flow `span()`) — needs a design note before implementation,
   language-side, blocks on Jake per `DESIGN.md`.
2. Close the native PDF backend's known gaps: images, math typesetting, non-ASCII glyphs,
   fine page-break control (README states these as current limitations).
3. No other open threads — splitting `strikedown.zig` is deliberately deferred until it
   crosses ~2000 lines (currently ~1200).
**Traps:**
- `zig build test` prints benign `failed command: ./.zig-cache/.../test ... --listen=-`
  lines to stderr even on full success — read the `Build Summary: N/N steps succeeded;
  M/M tests passed` line, not the presence/absence of "failed" text.
- `strike render <file> --header f.sxh` on a single file does **not** read the surrounding
  project's `strike.yaml` (`theme:`, `theme_file:`) — that's project/site config, only
  `strike build`/`strike serve` on a directory resolves it. Don't use single-file render to
  check theme wiring; build the directory and inspect the output instead.
**Pointers:**
- `dev/DECISIONS.md` — D1: `flow(n)` Candidate A, D2: native Zig PDF over Chromium export.
- `docs/reference/design/022-paginated-columns.md` — `flow(n)`'s home; status "shipped,
  pagination policy provisional" is the open thread in Next #1.
- `build.zig:37-56` — test step walks `src/` recursively (`Dir.walk`), so any new file
  anywhere under `src/` becomes a test root automatically, including `src/strikedown/`.
- `src/theme_file.zig`, `src/themes.zig`, `src/render_pdf.zig` — have rejection-path/
  invariant/geometry tests as of the v0.2.0 close-out.

## Task: Full-site nav, always-rooted breadcrumb, open-by-default folders · 16:05
**Goal:** A reader on any page of a strike site sees the whole site's nav, a brand path
that always starts at the root, and folders expanded by default — with `strike.yaml`
able to restore any of the old behaviors.
**Now:**
- `renderNav` (`site.zig:249`) renders one project's tree; `renderPickerNav`
  (`site.zig:319`) renders the whole site but is used only on `/`.
- `renderDocPage`/`renderProjectHome` (`site.zig:218`, `:178`) take a `Project`, never
  the `Site`, so they can't build a full nav today.
- `writeBrand` (`shell.zig:170`) emits at most `site / project`; folders never appear.
- Folder `<details>` are `open` only when they contain the active route (`site.zig:270`);
  the picker's project nodes are unconditionally `open` (`site.zig:336`).
- `renderAll` (`site.zig:46`) is the single entry point for both `serve` and `build` and
  already holds the `Site`.
**Scope.**
In: full nav on every page; multi-segment brand breadcrumb; folders open by default; a
`nav:` map in the site `strike.yaml`; `UI.md` + `STRIKE_YAML.md` rewrites; a D3 in
`dev/DECISIONS.md`; tests.
Out: banner images (own task — needs a `docs/reference/design/023-banner.md` draft first,
per `DESIGN.md`); narrow-screen nav (still hidden below `50rem`, the standing UI.md
limitation); per-project `nav:` overrides; PDF backend.
**Constraints:**
- `UI.md` binds UI work — it must be edited in the same change, not after.
- `docs/reference/DESIGN.md`: this is toolkit-side (how documents are *navigated*), so no
  design note is required. Keep it that way — nothing here may change what a document
  means.
- The reader-state contract (`UI.md`) must stay accurate: `nav:<slug>/<path>` and
  `nav:<slug>` keys keep their current meaning and spelling, so existing readers' saved
  collapse state survives.
- "A configured default is a default, not an override" — a reader who collapsed a folder
  still wins over `open: true`.
- Fail-soft yaml, like every other key: an unrecognized `nav:` value falls back to the
  default rather than erroring.
- *Assumption:* `nav:` is site-scope only. Nav shape is a whole-site property; a
  per-project override would let two pages of one site disagree about what the sidebar is.
- *Assumption:* a breadcrumb segment for a folder **without** a `main.*` renders as plain
  text, not a link — that folder has no page to link to (`STRIKE_YAML.md`, `main.*`).
**Approach:**
1. **Config.** Add `NavConfig { scope: enum{full,project} = .full, open: bool = true,
   breadcrumb: bool = true }` to `project.zig`, parsed from the site `nav:` map in
   `project.load` (`project.zig:156`) with `yaml.Value.get`/`getScalar`, read strictly
   like `serve:` (literal `true`/`false`). Store on `Site`; copy onto `Project` the way
   `base`/`season` already are (`project.zig:73`), so the render functions can reach it.
2. **Full nav.** Give `renderPickerNav` an `active_route` parameter and have it pass that
   through to `renderNavList`. Add `siteNav(gpa, site, active) []u8`: if a root project
   exists (`slug == ""`) it is `renderNav` on that project's tree (a root project already
   *is* the whole site); otherwise `renderPickerNav`. Change `renderDocPage` and
   `renderProjectHome` to take `site` alongside `p` and call `siteNav`; when
   `nav.scope == .project`, keep today's `renderNav`. `renderAll` (`site.zig:46`) is the
   only non-test caller, so the signature change is contained.
3. **Breadcrumb.** Add `breadcrumbSegments(gpa, site, p, route) []Segment` in `site.zig`
   (`Segment = { label, href: ?[]const u8 }`), built by walking `p.tree` for the folder
   chain that contains `route` — the same recursion `navContainsActive` (`site.zig:298`)
   already does, returning the path instead of a bool. Segment 0 is always the site root
   (`site.title` → `homeHref(site.base)`); then the project (`p.title` →
   `projectHref`) in picker mode; then one segment per ancestor folder, linked to its
   `main.*` route when it has one. Replace `Shell.site_title`/`site_href` (`shell.zig:37`)
   with a `crumbs: []const Segment` slice and rewrite `writeBrand` (`shell.zig:170`) to
   emit `<a class="brand-site">` for every segment but the last and `<a class="brand-home">`
   for the last, joined by the existing `<span class="brand-sep">/</span>`. `breadcrumb:
   false` collapses to today's one-or-two-segment form. `shell.standalone` passes no crumbs.
4. **Open by default.** Thread `open_default: bool` into `renderNavList` and OR it with
   the existing `own_active or navContainsActive(...)` (`site.zig:270`).
5. **No open-flash.** The folder-state restore loop currently runs in `page_tail`
   (`shell.zig:724-732`), after paint — with everything open by default a reader who
   collapsed folders would see them all snap shut. Move that loop into a small inline
   `<script>` spliced immediately after `</nav>` (`head_post_d_a`, `shell.zig:572`), where
   the `<details>` elements exist but the page hasn't painted. The `toggle` listener can
   stay with it; nothing else in `page_tail` depends on it.
6. **Docs + decision.** Rewrite `UI.md`'s "Self-contained projects" bullet (it lives under
   "How values resolve" in `STRIKE_YAML.md:198` too) and the brand bullet; add `nav:` to
   `STRIKE_YAML.md`'s key-reference table and a short section; write D3 in
   `dev/DECISIONS.md` recording full-nav-everywhere over project-scoped nav, with
   "revisit if" tied to nav size on large sites.
**Risks:**
- *Nav length.* A big multi-project site now renders every document in every page's HTML.
  Noticed by: `docs/` build output size, and by scrolling the sidebar on a `reference`
  page. Mitigation already in hand: `scope: project` restores the old behavior.
- *Signature churn.* `renderDocPage`/`renderProjectHome` gaining a `Site` parameter
  touches the ~8 site.zig tests that call them directly (`site.zig:408-762`). Noticed by:
  compile errors, which is the good failure.
- *Brand markup change.* `site.zig:624`, `:631`, `:719`, `:743`, `:762` assert exact
  `brand-site`/`brand-home` strings. They must be rewritten, not deleted — they are the
  regression net for the "root is always root" rule.
- *localStorage collision.* Project nodes key on a bare slug, folders on `slug/path`
  (`site.zig:314` explains why they can't collide). Full nav uses both on the same page
  for the first time. Noticed by: collapsing a project node and a same-named folder and
  reloading.
**Done when:**
- On `docs/` built with `strike build`, a page deep in `reference` shows `example` and
  its documents in the sidebar, not just `reference`'s tree.
- The brand's first link is `/` (or the base) from every page of a picker site *and* of a
  root-project site.
- Opening `/reference/design/022-paginated-columns` shows a brand reading
  `strikedown / reference / design / …`, with `design` plain text if that folder has no
  `main.*` and a link if it does.
- Every nav folder renders open on a first visit in a clean browser profile; collapsing
  one and reloading keeps it collapsed, with no visible open-then-close flash.
- `nav: {scope: project}` in `docs/strike.yaml` restores today's per-project sidebar;
  `open: false` restores today's ancestors-of-active-only disclosure; `breadcrumb: false`
  restores the one-or-two-segment brand.
- A garbage `nav:` value (`scope: sideways`) falls back to the default and doesn't crash.
- `zig build` clean and `zig build test --summary all` passes every step (read the
  `Build Summary: N/N steps succeeded; M/M tests passed` line — the `--listen=-` stderr
  noise is benign, per the journal's Traps).
- `UI.md`, `STRIKE_YAML.md` and `dev/DECISIONS.md` (D3) reflect the new defaults.
**Open:** none blocking. Banner images are deferred to their own task, starting from a
draft `docs/reference/design/023-banner.md`.

## Close · 2026-09-22 15:42 · b4e530f..fb275a4
- **changed:** `src/project.zig`/`src/site.zig`: `nav: {scope, open, breadcrumb}` config;
  full-site nav is now the default; sidebar brand is a 2-segment-max breadcrumb
  (root + nearest project/folder, `..`-compressed when deeper).
  `src/shell.zig`: breadcrumb segments render as stacked block-level lines (no `/`
  separator, no mid-line wrap); fixed a sidebar horizontal-scroll bug (folder labels now
  ellipsis-truncate; `.sidebar-head`/`.sidebar-nav` got `min-width: 0` — the flex-item
  default-`auto` gotcha that let long names push the fixed-width sidebar wider).
  `src/themes.zig`: Vanta Black's accent changed cyan (`#00D9FF`) → off-white
  (`#EDEAE0`); `Palette` gained a per-theme `on_accent` field (default `#fff`) so
  `.nav-doc.active` text stays legible against the lighter accent.
  `docs/reference/{UI,STRIKE_YAML}.md`, `dev/DECISIONS.md` (D3) updated to match.
- **why:** project-scoped nav + ancestors-only-open folders forced a trip through `/` to
  reach a sibling doc; user asked for full-site nav + a root-anchored breadcrumb, then
  live-iterated it down to a hard 2-line cap (a 4-segment brand was wrapping the sidebar
  header) and then to real vertical stacking (still wrapping/joining oddly inline); a
  separate report of horizontal scroll on long nav labels turned out to be the same
  family of bug (unclipped folder-summary text + a flex min-width default); vanta-black's
  cyan accent was a plain aesthetic ask.
- **verified:** `zig build` clean; `zig build test --summary all` → 39/39 steps,
  1842/1842 tests passed (ran repeatedly through the session, last run immediately before
  committing). Also checked visually with headless-Chromium screenshots against the real
  `docs/` corpus: nav depth (a `reference/` page shows `example/`'s docs), breadcrumb
  compression (`strike documentation` / `..Design notes`), no horizontal scrollbar on the
  longest real labels, and vanta-black's off-white active-nav-item contrast.
- **by:** pair — Jake drove every design call (defer banner; cap the breadcrumb at 2;
  stack instead of inline; off-white accent); I implemented and verified each.
- `fb275a4` Full-site nav, capped breadcrumb, sidebar overflow fix, vanta-black accent
- 6 files, +622 −200

### Next
1. Banner images: still deferred — start with a draft `docs/reference/design/023-banner.md`
   (2–3 syntax candidates, degradation story, corpus grep) per `DESIGN.md`; Jake dictates
   the Decision before any implementation.
2. Design note 022's pagination policy (widow/orphan, oversize-block, in-flow `span()`) —
   unchanged, still blocked on Jake.
3. PDF backend gaps (images, math typesetting, non-ASCII, fine page-break control) —
   unchanged.

### Traps
- `zig build test` prints benign `failed command: ...--listen=-` stderr lines even on
  full success — read the `Build Summary: N/N steps succeeded; M/M tests passed` line.
- `strike render <file>` never reads the surrounding `strike.yaml` — build/serve a
  directory to check `nav:`/theme/etc. wiring, not single-file render.
- Full-site nav (the new default) puts every project's whole doc list into every page's
  HTML — fine for this repo's size, but check `nav: {scope: project}` before assuming a
  large multi-project site's page weight is acceptable.
- A near-white/light theme accent needs its own `Palette.on_accent` override (see
  vanta-black) — white-on-accent (`.nav-doc.active`) is the element that breaks first.

### Pointers
- `dev/DECISIONS.md` D3 — full-site nav / open-by-default folders / capped breadcrumb;
  amended twice in-session (uncompressed → `..`-compressed, then inline-joined →
  block-stacked). Read D3 before touching sidebar/breadcrumb layout again.
- `src/site.zig`: `breadcrumbSegments` — the 2-segment cap + `..` compression;
  `collectAncestors` — the folder-chain walk it compresses; `siteNav` — picks
  `nav.scope`.
- `src/shell.zig`: `writeBrand` — one block-level `<a>`/`<span>` per crumb segment, no
  separator; `.sidebar-head`/`.sidebar-nav { min-width: 0; }` is why the ellipsis rules
  actually take effect (flex items default to `min-width: auto`).
- `src/themes.zig`: `Palette.on_accent` — new field, pair any future light/near-white
  accent with a dark override the way `vanta_black` does.
- No decisions this session fall outside D3 — it was amended live to cover all of it, so
  `/decide` isn't needed.
