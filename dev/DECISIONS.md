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

## D4 · 2026-09-23 · `root:` — an external root link for a site mounted under a parent site

**Decision:** `strike.yaml` `root:` (site-scope) points the sidebar brand's root segment
at an external URL instead of this site's own `/` — but only when `base:` is also set,
and only when `root:` is an `http://`/`https://` URL; any other combination is ignored,
fail-soft, like every other yaml key. `root_label:` names that segment, defaulting to the
URL's host. When active, the brand becomes exactly two fixed segments on *every* page —
`root:`'s target first, then this site's own title linking to its own `/` (or mount
base) — replacing D3's "root is always root, then at most one more segment for the
nearest project/folder" scheme entirely for that page; there is no third segment for the
page's own folder depth in this mode.

**Why:** Jake is mounting a project (e.g. a weblog) as a subroute of a bigger personal
site (`base: /weblog` under `jake.example`). The reader's fastest click home should reach
the *parent* site, not loop back into the subroute — but the subroute still needs its own
one-click front page, since the external root no longer serves that role. Gating on
`base:` means an external root link only appears for a site that structurally *is* a
subroute of something else; it can't be set (accidentally or not) on a site that owns its
own domain root, where it would leave no path back to `/` at all. Dropping the
project/folder chain (rather than appending it as a third segment) keeps the two-line
brand shape D3 just set — the fastest way back to "where am I on this subsite" is already
one click away in the full-site sidebar nav beside it, not the brand.

**Rejected:**
- Adding the local-root segment as a *third* line alongside the existing project/folder
  chain: breaks D3's just-set two-segment cap (the reason for that cap — a design-note
  page growing a four-segment brand — applies just as much with a third fixed segment
  added on top), and Jake's own phrasing ("the second breadcrumb always to the root level
  main.sx/md file") named exactly two segments.
- Allowing `root:` without requiring `base:`: an external root link only makes sense
  when this site is itself mounted as somebody else's subroute; without `base:` there'd
  be no coherent "local front page" for the second segment to represent.
- Requiring `root_label:` instead of defaulting it: the URL's host is almost always the
  right label and free to derive, so requiring it would be yaml ceremony with no payoff
  the common case needs.

**Revisit if:** a reader loses too much "where am I" context on a deep page once the
folder/project breadcrumb chain disappears — the sidebar nav is assumed to cover it, but
if that assumption is wrong for a real site, the fix would be a third, folder-chain
segment appended after the two fixed ones (not reverting to D3's original scheme, which
still couldn't reach an external parent).

## D5 · 2026-09-23 · A third, optional subfolder segment in `root:` mode, styled root-first

**Decision:** `root:` mode's brand grows an optional third segment appended after D4's
two fixed ones, for the current page's nearest project/folder — reusing the same
chain-compression `collectAncestors` already walks in the non-`root:` path, omitted when
that chain is empty (i.e. on the base route's own front page). Styling flips from D4's
position-based rule: the root segment is now always the bold/prominent one
(`brand-home`-style), and both the base segment and the subfolder segment are muted
(`brand-site`-style), each with a literal `/` baked into its label text (`/weblog`,
`/notes`) rather than a separate separator glyph.

**Why:** Jake is mounting a project under a parent site he wants to feel like "home" —
the root link should read as the dominant brand element, with the local mount and its
current subfolder as secondary wayfinding beneath it. This is exactly the case D4's own
"Revisit if" named in advance: a deep page losing "where am I" context without the
folder chain.

**Rejected:**
- Giving the base segment its own intermediate weight distinct from the subfolder
  segment: adds a third visual tier for no signal it needs to carry — reader only needs
  "root vs. everything below it."
- A CSS-drawn separator glyph between segments: D3 deliberately avoids inter-segment
  glyphs to keep the stacked brand from wrapping; baking `/` into the label text gets
  the path-like look Jake wants without reopening that rationale.

**Revisit if:** a site with `root:` set but very deep nesting still wants more than one
folder-chain segment — today's compression still caps it at one, same as D3.

## D6 · 2026-09-23 · `root:` also accepts a local absolute path, not just `http(s)://`

**Decision:** `resolveRootLink`'s gate widens from `isAbsoluteUrl(root)` to
`isAbsoluteUrl(root) or root` starting with `/` — a bare local path like `root: /` or
`root: /site-content` now activates `root:` mode too. `root_label:` becomes *required*
when `root:` is a local path (no `urlHost()`-style default exists for a bare path); the
`http(s)` case keeps its existing free host-derived default.

**Why:** Jake's dev server shouldn't hyperlink out to the live production domain while
testing — he wants the same `root:`/`base:` breadcrumb shape to work locally by pointing
`root:` at a local path instead.

**Rejected:**
- Leaving `root:` URL-only and having Jake hand-edit the yaml value between dev and
  prod: no code change, but reintroduces exactly the kind of manual toggling `root:`/
  `base:` were built to avoid, and risks a real URL accidentally shipping in a dev
  config or vice versa.

**Revisit if:** a local `root:` path and `base:` ever collide or overlap in a way that
makes the two fixed segments link to the same place — not expected given `base:` is
always relative to this site's own mount, but untested.
