# Journal · 2026-09-23 13:00 · slopbox · 199a827
## Start
**State:** Folder-hiding bug fixed, `sidebar_width:` and `root:`/`root_label:` yaml keys
shipped in `0ead3a6` — build/test verified, docs updated. D4 recorded (root-link
breadcrumb, two fixed segments, revises D3). Nothing uncommitted.
**Since:** nothing — session opened with `/frame`, no new commits.
**Next:** carried from the previous Close:
1. Root link is implemented per D4's two-fixed-segment shape; if a real deep site loses
   too much "where am I" context without the folder chain, D4's own "Revisit if" names
   the fix (a third, folder-chain segment appended after the two fixed ones) — this is
   now the task below, raised by Jake directly rather than found later.
2. Banner images (M) — draft `docs/reference/design/023-banner.md`, Jake dictates the
   Decision before implementation.
3. Design note 022 pagination policy (M) — blocked on Jake.
4. PDF backend gaps (L) — unscoped.
**Traps:**
- `zig build test` prints benign `failed command: ...--listen=-` stderr even on full
  success — read the `Build Summary: N/N steps succeeded; M/M tests passed` line.
- `strike render <file>` never reads the surrounding `strike.yaml` — build/serve a
  directory to check `nav:`/`root:`/`sidebar_width:`/etc. wiring.
- The "skip empty folders" rule now applies at two levels (`scan()` for subfolders,
  `loadProject` for top-level project folders) — if a third layer of folder-like
  grouping is ever added, it needs the same check.
- No headless-browser tooling installed; reading the built HTML directly (`grep`/Python
  regex on the output file) was enough to verify last session's changes.
**Pointers:**
- `src/project.zig`: `resolveRootLink`/`isAbsoluteUrl`/`urlHost` (site-scope `root:`
  resolution) sit right after `resolveNavConfig`.
- `src/shell.zig`: `sidebarWidthToken` sits by `safeDecimal`. `writeBrand` (~205-223)
  assigns `brand-home`/`brand-site` by position (last = bold); CSS at ~530-534.
- `src/site.zig`: `breadcrumbSegments`'s `root:` early return (394-400) sits before the
  existing chain-collapsing logic (401-420), which calls `collectAncestors` (422-437) —
  currently unreachable once `root:` short-circuits.
- `dev/DECISIONS.md` D4 — the root-link decision; D3 is still the reference for the
  no-`root:` default case and the no-separator stacked-line brand.

## Task: three-segment root-link breadcrumb (revising D4) · 13:00
**Goal:** When `root:`+`base:` are set, show an optional third breadcrumb segment for the
current subfolder, with the external root link styled as the bold/prominent one —
matching Jake's weblog-under-a-parent-site layout.
**Now:**
- D4 (`dev/DECISIONS.md:100-139`) made `root:` mode render exactly two fixed segments —
  root target, then site title → `homeHref(base)` — dropping the project/folder chain
  entirely on every page (`site.zig:394-400`).
- `writeBrand` (`shell.zig:205-223`) gives only the *last* segment `brand-home` (bold,
  inherits color); every earlier segment gets `brand-site` (muted, `.85em`,
  `shell.zig:530-534`). In `root:` mode today that makes the root segment small/muted
  and the local site title bold — the opposite of what Jake wants now.
- D3's stacked-line brand deliberately has no `/` separator between segments
  (`shell.zig:1027-1031` test) — each segment is its own block line. Jake's ask
  ("`/weblog`", "one extra breadcrumb with a slash `/`") implies a different, path-style
  joiner for segments 2-3.
- The chain-compression helper (`collectAncestors`, `site.zig:422-437`) that would
  produce a subfolder segment already exists and is used in the non-`root:` path
  (`site.zig:408-419`) — it's just unreachable once `root:` short-circuits.
- D4's own "Revisit if" (`dev/DECISIONS.md:136-139`) named exactly this case; last
  session's journal Next #1 flagged it as something to watch once the weblog is live.
**Scope:**
- In: extend `breadcrumbSegments`'s `root:` branch to optionally append a third,
  compressed subfolder segment; restyle which segment(s) are bold vs. muted; widen
  `root:`'s accepted value (see wrinkle below).
- Out: `sidebar_width`, folder-hiding (both closed last session).
**Constraints:**
- This revises D4 (which itself revised D3) — record via `/decide` before implementing,
  not slipped in quietly.
- Reuse `collectAncestors`'s existing compression rather than a new chain-walk.
- Don't regress D3's plain 2-segment case (no `root:`) — its "last segment = bold" rule
  still needs to hold there.
**Approach:**
- Third segment: reuse `collectAncestors` (`site.zig:422-437`) inside the `root:`
  branch, appended only when the chain is non-empty — i.e. omitted on the base route's
  own front page (`/weblog` itself), same trigger the non-`root:` path already uses.
- Styling: role-based, not position-based — root segment always gets the bold/prominent
  style; base + subfolder both get today's muted `brand-site` style. Gate this on
  `root:` mode specifically so D3's plain case is untouched.
- Separator: bake `/` into each non-root segment's label text (e.g. label `/weblog`,
  `/notes`) rather than a new CSS glyph — cheapest, avoids reopening D3's
  wrap-avoidance rationale.
**Risks:** a blanket change to `writeBrand`'s bold/muted logic could regress D3's
existing 2-segment brand if not gated specifically to `root:` mode.
**Done when:** a Decision is recorded in `dev/DECISIONS.md` (via `/decide`) naming the
three-segment shape, the styling split, and the separator convention; then implemented,
`zig build test` green, and verified against a 3-deep scratch site with `root:`+`base:`
set (root bold, `/weblog` and `/subfolder` muted with slashes, no third segment on the
`/weblog` front page itself).
**Resolved (Jake, this session):**
1. Styling split — root bold, base + subfolder both muted (as recommended).
2. Separator — literal `/` baked into label text (as recommended).
3. `base:` gating — confirmed already correct: `resolveRootLink` (`project.zig:194-199`)
   only requires `base.len > 0`; only `root:` itself is checked against
   `isAbsoluteUrl` (`project.zig:201-203`). `base:` was always a plain local path
   (e.g. `/weblog`), never URL-checked — no fix needed, just don't add a spurious URL
   check on `base` when wiring the third segment.

**Wrinkle (Jake, this session): `root:` needs a local-path form for dev.** Jake doesn't
want the dev server linking out to the live domain — wants `root: /` or `root:
/site-content` to work. Conflicts with D4 as recorded: `resolveRootLink`
(`project.zig:194-203`) only activates `root:` for `http://`/`https://`; any other value
is silently ignored (fail-soft) — so `root: /` today just falls back to normal
breadcrumb behavior, not a local link. Two options:
1. **(Jake's pick)** Widen the gate to `isAbsoluteUrl(root) or startsWith(root, "/")`.
   `root_label:` becomes *required* in the local-path case (no `urlHost()`-style default
   exists for a bare path) — `http(s)` case keeps today's free host-derived default.
2. Leave `root:` URL-only (matches D4's "external root link" framing) and have Jake
   swap the yaml value by hand between dev and prod — no code change.
Jake confirmed option 1 in chat (2026-09-23). This is a second amendment to D4, same as
the three-segment shape above — both belong in the same `/decide` update.
**Open:** none — ready for `/decide` then implementation.

## Close · 2026-09-23 13:10 · 199a827..0d2fbfc
- **changed:** `src/site.zig`: `breadcrumbSegments`'s `root:` branch grows an optional
  third segment (current page's nearest project/folder, `/`-prefixed, reusing
  `collectAncestors` via new shared helper `projectFolderChain`); segment 2's label is
  now the literal `base:` path, not `site.title`; root segment is bold, base/folder
  segments muted. Also fixed `renderPickerPage`, which hardcoded its own single crumb
  and so silently dropped `root:` mode's brand entirely on a picker-mode site's own
  front page. `src/shell.zig`: `Segment` gained an optional `bold` field so `writeBrand`
  can mark the first segment bold instead of its D3 default (last segment). `src/
  project.zig`: `resolveRootLink` now also accepts a local absolute path (`/…`) for
  `root:`, requiring `root_label:` in that case. Docs (`STRIKE_YAML.md`, `UI.md`)
  updated to match.
- **why:** Jake's weblog-under-`fake_example.dev` deployment (`/frame`'d this session)
  needed the sidebar brand to read root-first (bold) with the local mount and current
  folder as secondary lines, and needed `root:` usable on a dev server without linking
  out to the live domain — both amend D4, recorded as **D5**/**D6** via `/decide` before
  implementing.
- **verified:** `zig build test` → `Build Summary: 39/39 steps succeeded; 1876/1876
  tests passed`. `strike build` against a scratch 3-deep site with `root:`+`base:` set:
  root bold linking out, `/weblog` and `/Design`/`/Reference` muted with slashes, no
  third segment on the base route's own front page, correct brand on the picker's own
  front page (the bug fix), unlabeled local-path `root:` correctly falls back to the
  default breadcrumb.
- **by:** claude
- `0d2fbfc` Three-segment root-link breadcrumb; root: accepts a local path (D5, D6)
- 5 files, +177 −50

### Next
1. If Jake wants segment 2 to show a human title (`Weblog`) instead of the raw `base:`
   path (`/weblog`) in `root:` mode, that's a further change to what shipped this
   session — needs its own `/decide`, not a quiet edit (raised in chat, not yet asked
   for).
2. Banner images (M) — draft `docs/reference/design/023-banner.md`, Jake dictates the
   Decision before implementation. Still deferred.
3. Design note 022 pagination policy (M) — still blocked on Jake.
4. PDF backend gaps (L) — still unscoped.

### Traps
- `zig build test` prints benign `failed command: ...--listen=-` stderr even on full
  success — read the `Build Summary: N/N steps succeeded; M/M tests passed` line.
- `strike render <file>` never reads the surrounding `strike.yaml` — build/serve a
  directory to check `nav:`/`root:`/`sidebar_width:`/etc. wiring.
- A root `main.*` alone does **not** create a root project — a content root with only
  subfolders (no loose `.md`/`.sx` files directly in it) is picker mode, and the root
  `main.*` becomes the picker's own content, not a project home (`STRIKE_YAML.md:178-
  198`). This is exactly what made the picker-mode `root:` bug (fixed this session) easy
  to hit by accident when testing.
- No per-environment yaml profile exists — toggling `root:` between a live URL (prod)
  and a local path (dev) is a manual yaml edit; nothing in strike swaps it automatically.

### Pointers
- `src/site.zig`: `breadcrumbSegments` (`root:` branch ~396-411), `projectFolderChain`
  (the shared chain-building helper, ~424-430), `renderPickerPage` (~155-177, now calls
  `breadcrumbSegments` with a dummy empty `Project` instead of hardcoding its crumb).
- `src/shell.zig`: `Segment.bold` (optional, `null` = old last-segment-bold default),
  `writeBrand` (~205-227).
- `src/project.zig`: `resolveRootLink`/`isAbsoluteUrl`/`isLocalPath` (~189-216).
- `dev/DECISIONS.md` D5 (three-segment shape + bold styling), D6 (`root:` local-path
  form) — both amend D4; D4 is still the reference for the plain two-segment case.
