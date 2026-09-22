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

## D3 · 2026-09-22 · Full-site nav, open-by-default folders, and a capped, root-anchored breadcrumb as the defaults

**Decision:** Every page's sidebar now carries the whole site by default (`nav.scope =
.full`), not just the current project's tree; nav folders render open by default
(`nav.open = true`); and the sidebar brand is a **two-segment-max** breadcrumb
(`nav.breadcrumb = true`) — the site root (unconditional: "root is always root"), then
at most one more segment for the nearest thing below root (the project, or the page's
nearest ancestor nav folder, whichever is closer), each its own block-level line with no
`/` between them so the brand stacks instead of wrapping. Anything past that one segment
— a project *and* folders, or several nested folders — collapses into it: its label
gains a `..` prefix (`..design`, no separator), still linking to that folder's `main.*`
when it has one, plain text otherwise. All three are `strike.yaml` `nav:` keys (site-scope only
— nav shape is a whole-site property), each independently overridable back to the prior
behavior: `scope: project`, `open: false`, `breadcrumb: false` (which now means: site,
then project — no second segment for the page's folder at all). Jake dictated these as
toolkit defaults (no design note — `DESIGN.md`'s boundary: this changes how documents
are navigated, not what they mean).

**Why:** The old project-scoped sidebar and ancestors-only-open folders made crossing
between projects, or finding a sibling document, require a trip back through `/`; the
old one-or-two-segment brand couldn't express "where am I" once a project's own nav grew
folders. Full nav plus a root-anchored breadcrumb make every document one click from any
other and the way back always the same first click, regardless of how deep a page sits.
The breadcrumb started as *uncompressed* (one segment per ancestor folder), but Jake
revised that mid-session to a hard two-segment cap: a deep design-note page
(`reference/design/NNN-*.md`) grows a four-segment brand under the uncompressed rule,
and he wanted the brand short and predictable regardless of nesting depth, not scaling
with it. Capping at two segments with `..`-compression does that while the full path
stays one click away in the nav beside it.

**Rejected:**
- Leaving the old behavior as the default and adding `nav:` only as an opt-in toward the
  new one: the old defaults were the actual complaint, not a preference worth preserving
  by default.
- Gating the project breadcrumb segment on `Project.site_title` (only set in picker mode
  by `project.load`) instead of `Project.slug.len > 0`: several existing tests construct
  `Project` values directly, bypassing `load`, and only set `slug`; `site_title`-gating
  silently dropped their project segment. `slug` is the structural signal ("is this
  project distinct from the site root") and doesn't depend on how the `Project` was
  built. `site_title` itself was then dead code and removed.
- The initial uncompressed breadcrumb (one segment per ancestor folder, no cap):
  superseded within the same session once it proved to wrap on the repo's own deepest
  pages — see "Why".

**Revisit if:** `scope: full` makes the sidebar unusably long on a site with many large
projects — the escape hatch (`scope: project`) already exists; a future middle ground
(e.g. collapsed-by-default *other* projects, expanded current one) would be a new `nav:`
value, not a default change.
