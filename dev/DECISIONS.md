# Decisions

## D1 · 2026-09-18 · `flow(n)` as a flow group for paginated columns

**Decision:** Adopt Candidate A from `docs/reference/design/022-paginated-columns.md`: a
group-level `flow(n)` command (2–4 columns) that carries one source-ordered stream through
successive columns, then pages in a paged medium. `flow` is group-only and cannot combine
with `grid` on the same opener; title/abstract/other full-width material stays outside the
flow group. Full detail — problem statement, all three candidates, degradation analysis,
and the 2026-09-18 corpus grep — lives in the design note; this entry is the index pointer.

**Why:** Gives authors an explicit, bounded region for column flow without making any
heading or paragraph implicitly special (the header-setting alternative's weak point) and
without the fragility of hard per-page groups that break on a one-paragraph edit (the
explicit-page-sections alternative's weak point). A malformed or unrecognized `flow(n)`
degrades to ordinary prose in one column — reading order survives even on old renderers.

**Rejected:**
- Candidate B (document-header flow setting, e.g. `columns: 2` in `.sxh`): no clean way to
  say where a title/abstract/wide table stops or starts the flow without ad hoc exceptions
  that recreate Candidate A piecemeal.
- Candidate C (explicit `page(2)` sections): hard page boundaries are fragile to revise —
  adding one paragraph overflows a page, forcing either an implicit continuation (weakening
  the boundary) or a layout failure.

**Revisit if:** an in-flow `span()` (full-width element inside a flow group) is designed,
or the deferred pagination policy (widow/orphan behavior, oversize-block policy) turns out
to need a different container shape than a plain group.

## D2 · 2026-09-18 · Native Zig PDF backend over a Chromium-based export

**Decision:** `render_pdf.zig` walks the parsed block tree directly and writes PDF 1.4
objects itself — no headless browser, no external process.

**Why:** Keeps the no-external-dependency principle the project already states (README:
"no build-time dependencies beyond the Zig standard library"; the one runtime exception is
client-side MathJax from a CDN for math typesetting). A Chromium wrapper would add a large,
fragile runtime dependency the HTML path doesn't have. It also lines up with `MODEL.md`'s
backend rule — "a new backend is a new file walking the same tree," not an abstraction
layer — so PDF support is one more emitter, not a second rendering architecture.

**Rejected:**
- Chromium-based export (e.g. headless-browser print-to-PDF): would have reused CSS layout
  for free, but pulls in a large external dependency the rest of the toolkit has none of,
  and sidesteps `MODEL.md`'s tree-walking backend rule.

**Revisit if:** the PDF backend's known gaps (images, math typesetting, non-ASCII glyphs,
fine page-break control) prove too costly to build natively — see README's stated
limitations and the deferred pagination policy in design note 022.
