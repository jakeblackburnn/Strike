# Journal

## 2026-09-21 22:50 · base_md · a4d15a1 · devlog
Wrote and committed v0.0.1 as an orphan root commit: `src/doc.zig` (bare `Block`
union: heading/paragraph/code, no `Attrs`), `src/parse.zig` (line-based block loop +
`isBlockStart` companion + flow-joining + one-pass inline chain for code/strong/em),
`src/emit_html.zig` (walk + `page()` wrap), `src/html.zig` (escaping), `src/main.zig`
(`strike render` only). 12 tests across the two logic files, all green
(`zig build test`). Verified `zig build run`, `-o`, `--fragment`, and both CLI error
paths against `zig-out/bin/strike`. `dev/terms.md` written with the full vocabulary,
eight design-decision entries, and the backlog list; `dev/intent.md` explains the
restart. `README.md` cut to ~35 lines. `docs/`, `strikedown/`, `sandbox/`, `test.md`
all gone (not carried into the orphan tree). Next: branch `base_sx` off this commit
and add groups only.

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
