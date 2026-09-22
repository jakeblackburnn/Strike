# Journal · 2026-09-22 14:47 · slopbox · 6fd81d8
## Start
**State:** Tree committed and clean at `6fd81d8` (close-out of `056d7bb` "v0.2.0 -
Typography headers, theme files, flow columns, PDF backend", on `12f8432` v0.1.3).
`zig build` clean; `zig build test --summary all` → 39/39 steps, 1819/1819 tests passed
(stderr `failed command …--listen=-` on cached test binaries is benign runner noise — read
the summary line, not "failed" text). `docs/paper/` built and spot-checked: bootstrap JS
defaults to `data-season="custom"`, Paper Ink's palette inlined and selectable, `paper.pdf`
regenerated and validated with `pdfinfo` (2 pages, letter).
**Since:** Migrated `dev/` to the journal.md convention — `HANDOFF.md` and `devlog/` retired;
past sessions now read via `git log -p -- dev/journal.md` (their content is preserved there:
`HANDOFF.md` and `devlog/2026-09.md` up to this commit).
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
