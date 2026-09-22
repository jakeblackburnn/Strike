# Journal

## 2026-09-21 22:44 · base_md · (root commit) · brief
**Task:** Write v0.0.1 of both base branches (`base_md`, `base_sx`) — minimal,
human-directed restarts of strike, replacing the AI-written 0.1.x line for these
branches.
**Context:** `base_md`/`base_sx`/`slopbox` all sat at the same v0.1.2 commit
(11.6k lines, 16 files, ~365 tests, 21 design notes, no `dev/`). Decided: clean-slate
rewrite (slopbox read-only reference), `base_sx` branches off `base_md`, `base_md`
scope is parse+render only (`strike render`), md forms are a skeleton (heading,
paragraph, fenced code; code/strong/em inline), sx adds groups only (no commands, no
`Attrs`), `docs/` deleted in favor of a small `dev/` + `sample/`, history is an orphan
root commit.
**Approach:** Five source files (`html`, `doc`, `parse`, `emit_html`, `main`), ~800
lines with tests; `dev/terms.md` carries the actual terminology/design-decision
substance; `dev/intent.md` explains why the branches exist; two commits, one per
branch, each closing with a devlog entry.
**Open questions:** none blocking — all resolved before implementation (see the
brief shown in chat this session).
