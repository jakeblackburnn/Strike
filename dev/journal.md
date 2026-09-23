# Journal · 2026-09-23 12:28 · slopbox · 9e85106
## Start
**State:** Sidebar width control (±, 14–28rem, localStorage-persisted), wider collapse
hitbox, and default 8rem bottom document padding shipped in `abf2623` — build/test/
headless-browser verified. `docs/reference/UI.md` up to date. Nothing uncommitted.
**Since:** nothing — session opened with `/brief`, no new commits.
**Next:** carried from the previous Close:
1. Banner images (M) — draft `docs/reference/design/023-banner.md`, Jake dictates the
   Decision before implementation.
2. Design note 022 pagination policy (M) — blocked on Jake.
3. PDF backend gaps (L) — unscoped.
**Traps:**
- `zig build test` prints benign `failed command: ...--listen=-` stderr even on full
  success — read the `Build Summary: N/N steps succeeded; M/M tests passed` line.
- `strike render <file>` never reads the surrounding `strike.yaml` — build/serve a
  directory to check `nav:`/theme/etc. wiring.
- Full-site nav puts every project's whole doc list into every page's HTML — check
  `nav: {scope: project}` before assuming a large site's page weight is acceptable.
- A near-white/light theme accent needs its own `Palette.on_accent` override.
- No headless-browser tooling installed; the iframe-wrapper `chromium --headless
  --dump-dom` trick is how JS behavior got verified last session.
**Pointers:**
- `src/shell.zig`: sidebar-width buttons/handlers sit right after the `sidebar-edge`
  toggle script in `page_tail`; `SIDEBAR_MIN`/`SIDEBAR_MAX`/`SIDEBAR_STEP` (14/28/2) are
  the only place those numbers live.
- `src/shell.zig` head_pre_d_a: pre-paint `--sidebar-width` restore sits right after the
  `--content-width` restore — same no-flash pattern.
- `dev/DECISIONS.md` D3 — root-anchored, two-segment-max breadcrumb; unaffected by last
  session, directly relevant to this session's root-link task below.

## Task: strike.yaml customization — folder hiding, external root link, sidebar width default · 12:28
**Goal:** Give `strike.yaml` three more levers Jake wants for a personal-site deployment:
hide non-doc folders from nav, let the sidebar root link out to a parent site, and set a
site/project default sidebar width.
**Now:**
- `hidden:` (`project.zig:537-544`, `STRIKE_YAML.md:130`) already excludes named paths —
  files or folders — from nav and routes (404). Folders holding zero `.md`/`.sx` files
  are *already* excluded from nav with no config at all (`project.zig:371`, "skip empty
  folders") — confirmed against the asset-copy test at `main.zig:767-787`: an `img/`
  folder of only images never enters nav, but its files still get copied to static
  output on `strike build` (needed for `![]()` refs — that's correct, not a bug).
- `breadcrumbSegments` (`site.zig:382-404`) hardcodes the brand's first segment to
  `homeHref(site.base)` (local `/` or mount base). "Root is always root" is **D3**
  (`dev/DECISIONS.md`, dictated by Jake 2026-09-22), restated in `UI.md:48-65` and
  `STRIKE_YAML.md:218-221` ("no yaml key... no per-site repo link") /
  `STRIKE_YAML.md:239-244`.
- Sidebar width: `SIDEBAR_MIN/MAX/STEP` (`shell.zig:684`, 14/28/2) are compile-time
  constants; the reader's default (14rem) has no `strike.yaml` wiring, purely client
  `localStorage`. Content `width:` already has the exact pattern this would mirror
  (yaml key → `Options.width` → spliced into the no-flash JS bootstrap's unset-
  preference fallback; `project.zig:332`, `shell.zig` ~198-224).
**Scope:**
- In: (1) confirm/close the folder-hiding gap, if any. (2) a `strike.yaml` key for the
  sidebar's default width. (3) workshop + decide the external-root-link mechanism;
  implement only after Jake's Decision.
- Out: banner images, design note 022, PDF backend gaps (still on the Next list,
  untouched by this task).
**Constraints:**
- Toolkit-side (UI/config), not language — no `docs/reference/design/NNN` note needed
  (`DESIGN.md:50-52`); once decided, record via `/decide` into `dev/DECISIONS.md`.
- Fail-soft yaml handling throughout (`resolveNavConfig` is the template): unknown/
  malformed values fall back to defaults, never error.
- `hidden:`/`labels:`/`order:` are project-relative, exact-path matches, no globs today
  — new syntax should stay consistent with that unless Jake asks for globs.
- The root-link change **revises D3** ("root is always root") — must be recorded as a
  decision update, not slipped in quietly.
**Approach:**
- Root link: needs (a) the yaml surface — one absolute-URL key, e.g. `root:
  https://jake.example` (label default: hostname, or a paired `root_label:`) — and (b)
  once segment 1 points away, how a reader gets back to the project's own top
  (`/weblog`). Two candidate shapes to bring Jake: insert a new, always-present local-
  root segment (D3's 2-segment cap becomes 3 when `root:` is set), or fold the local
  root into the existing second segment (today's project/folder segment demotes to a
  third only when present). Worked brand examples for each before deciding.
- Sidebar width: add a `sidebar_width:` (name TBD) key resolved like `width:`, threaded
  through `Options`/`Shell`, spliced into the JS bootstrap's
  `localStorage.getItem("sidebarwidth")||"<default>"` fallback, clamped to
  `SIDEBAR_MIN..SIDEBAR_MAX`. Jake's `max` example is probably the ceiling (28rem today)
  rather than a literal keyword — default to a bare rem number for consistency with
  `width:` unless told otherwise.
- Folder hiding: likely no code change — pending Jake's answer to Open #1, at most a
  `STRIKE_YAML.md` clarification that folder-hiding already works today.
**Risks:**
- Implementing the root-link mechanism before Jake decides re-litigates D3 silently —
  exactly what `CLAUDE.md` says not to do.
- Guessing "max" as a keyword instead of confirming ships a yaml key whose shape has to
  change later.
**Done when:**
- Folder hiding: Jake confirms today's behavior covers the ask, or a named gap is fixed.
- Sidebar width: the new key sets `--sidebar-width`'s no-flash default on first paint (no
  saved `localStorage.sidebarwidth`); a reader's own resize still overrides it;
  `zig build test` passes; verified in a built page the way the width slider was last
  session.
- Root link: a Decision is recorded in `dev/DECISIONS.md` (via `/decide`) naming the
  yaml surface and breadcrumb shape before any implementation lands.
**Open:**
1. Folder hiding — is there a concrete case today's `hidden:` + auto-skip doesn't cover,
   or was this ask already satisfied and just needed confirming?
2. Root link — is `root:` (absolute URL + optional label) the right yaml shape, and
   should the local mount's own top gain a *permanent* extra breadcrumb segment, or
   fold into the existing second segment?
3. Sidebar width — bare rem number (matches `width:`) or a `max`/`min` keyword alias?

## Close · 2026-09-23 12:52 · 9e85106..0ead3a6
- **changed:** `src/project.zig`: `loadProject` now skips a top-level folder with
  zero `.md`/`.sx` anywhere in it (`scan()` already did this one level down —
  the actual bug Jake hit testing folder hiding); added `sidebar_width:` (site/
  project) and `root:`/`root_label:` (site-scope) yaml keys.
  `src/shell.zig`: `sidebarWidthToken` resolves `min`/`max`/bare-rem into the
  bootstrap's `sidebarwidth` fallback, clamped to 14–28. `src/site.zig`:
  `breadcrumbSegments` short-circuits to two fixed segments (`root:`'s target,
  then this site's own front page) whenever `root:` is set, replacing the
  project/folder chain entirely in that mode. Docs updated: `README.md`,
  `STRIKE_YAML.md`, `UI.md`.
- **why:** three `strike.yaml` customization asks from Jake's personal-site
  deployment (`/frame`'d this session): the folder-hiding ask turned out to be
  a real bug, not a missing feature; sidebar width and root link were net-new
  keys, root link answered by Jake mid-session (root:+base:, two fixed
  segments, no third folder-chain segment) — recorded as **D4** since it
  revises D3's breadcrumb rule.
- **verified:** `zig build test` → `Build Summary: 39/39 steps succeeded;
  1869/1869 tests passed`. `strike build` against scratch content dirs,
  inspected the output HTML directly: an images-only top-level folder no
  longer appears in the picker/nav (still copied as a static asset);
  `sidebar_width: max` produced
  `localStorage.getItem("sidebarwidth")||"28"` in a built page; `root:
  https://jake.example` + `base: /weblog` produced a two-segment brand
  (`jake.example` → external URL, `Weblog` → `/weblog`) on a page 3 folders
  deep, with no `..`-compressed third segment.
- **by:** claude
- `0ead3a6` Empty top-level folders no longer become picker projects; sidebar_width and root: yaml keys
- 6 files, +315 −23

### Next
1. Root link is implemented per D4's two-fixed-segment shape; if a real deep
   site loses too much "where am I" context without the folder chain, D4's
   own "Revisit if" names the fix (a third, folder-chain segment appended
   after the two fixed ones) — not blocking, just watch for it once Jake's
   weblog is live.
2. Banner images (M) — draft `docs/reference/design/023-banner.md`, Jake
   dictates the Decision before implementation. Still deferred, untouched
   this session.
3. Design note 022 pagination policy (M) — still blocked on Jake.
4. PDF backend gaps (L) — still unscoped.

### Traps
- `zig build test` prints benign `failed command: ...--listen=-` stderr even
  on full success — read the `Build Summary: N/N steps succeeded; M/M tests
  passed` line.
- `strike render <file>` never reads the surrounding `strike.yaml` — build/
  serve a directory to check `nav:`/`root:`/`sidebar_width:`/etc. wiring.
- The "skip empty folders" rule now applies at two levels (`scan()` for
  subfolders, `loadProject` for top-level project folders) — if a third
  layer of folder-like grouping is ever added, it needs the same check; it's
  easy to add a new grouping construct and forget this.
- No headless-browser tooling installed; reading the built HTML directly
  (`grep`/Python regex on the output file) was enough to verify this
  session's changes — no need for the iframe/chromium trick unless testing
  live JS interaction (e.g. the `−`/`+` sidebar buttons) again.

### Pointers
- `src/project.zig`: `resolveRootLink`/`isAbsoluteUrl`/`urlHost` (site-scope
  `root:` resolution) sit right after `resolveNavConfig`; the top-level empty-
  folder skip is one guard clause in `loadProject`, right after `scan()`
  returns.
- `src/shell.zig`: `sidebarWidthToken` sits by `safeDecimal`; its two hardcoded
  constants (`sidebar_min`/`sidebar_max` = 14/28) mirror — by hand, not a
  shared source — the JS `SIDEBAR_MIN`/`SIDEBAR_MAX` in `page_tail`'s stepper.
  Keep both in sync if that range ever changes.
- `src/site.zig`: `breadcrumbSegments`'s `root:` early return sits right at
  the top of the function, before the existing chain-collapsing logic.
- `dev/DECISIONS.md` D4 — the root-link decision Jake dictated this session;
  D3 is still the reference for the no-`root:` default case.
