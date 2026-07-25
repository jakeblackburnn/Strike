# 009 — Alerts (`> [!NOTE]`, superset deltas)

**Status: accepted** (decision dictated by Jack, 2026-07-20)

## Problem

`> [!NOTE]` and friends — GFM's alert blockquotes — render as literal text.
Closing the GFM gap itself needs no design note (docs/DESIGN.md); GFM is the
spec: a blockquote whose first line is exactly `[!TYPE]` becomes a styled
callout titled by its type. This note records only the **superset deltas**
strikedown adds on top, since those change what a document means beyond GFM.

## Terminology

- **Alert** — a blockquote carrying a recognized type marker; renderers give
  it a type-styled title and treatment. Unrecognized markers leave the
  blockquote plain (the marker stays literal text).

## Candidates

Two deltas were considered against a GFM-strict baseline:

### A — GFM-strict

Marker must sit alone on the quote's first line; types are exactly NOTE,
TIP, IMPORTANT, WARNING, CAUTION. `> [!NOTE] asdf` stays a plain quote with
literal text, as on GitHub.

### B — same-line text

`> [!NOTE] quick one-liner` is an alert whose trailing text starts the first
paragraph — the form people naturally type. GFM-authored documents are
unaffected (on GitHub that line renders literally, so real documents don't
use it — or use it *wanting* this).

### C — extra types

A small strike-flavored extension beyond the five (TODO, EXAMPLE,
QUESTION), versus the full Obsidian-style callout vocabulary (a dozen-plus
types, each needing distinct styling across eight seasonal palettes).

## Degradation analysis (mandatory)

The marker only activates inside a blockquote, as its first content, in the
exact shape `[!` + known type + `]`. Everything else — unknown types
(`[!IDEA]`), mid-quote markers, `[!NOTE` unterminated, `[! NOTE]` — is
literal quote text, byte-for-byte today's rendering. The same-line delta
(B) and extra types (C) activate only text that GitHub renders literally,
the standard superset posture. Type matching is case-insensitive, as on
GitHub itself. Corpus check: zero hits for `> [!` in `strikedown/` and
`docs/` at decision time.

## Decision

Dictated: **B and the small-set C**.

- Types: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION` (GFM), plus
  `TODO`, `EXAMPLE`, `QUESTION` (strike extras). Case-insensitive.
- The marker must be the quote's first content. Alone on its line (GFM
  form) or with trailing text, which becomes the start of the first
  paragraph. Everything after follows normal blockquote rules — paragraph
  merging, bare-`>` breaks, lazy continuation.
- An unknown type is not an error: the blockquote is plain and the marker
  is literal text.
- Rendering: the alert keeps blockquote structure and gains a title line
  from its type (`Note`, `Tip`, …) plus type-keyed styling. HTML:
  `<blockquote class="sx-alert sx-alert-<type>">` with a leading
  `<p class="sx-alert-title">` — colors come from theme roles / palette
  variables, never fixed RGB (note 006's posture), so alerts follow the
  reader's season. A fragment without reader CSS degrades to an ordinary
  blockquote whose first line names its type — readable, never broken.

## Canonical examples

```
> [!NOTE]
> body line one
> body line two
```

→ `<blockquote class="sx-alert sx-alert-note">\n<p
class="sx-alert-title">Note</p>\n<p>body line one body line
two</p>\n</blockquote>`

```
> [!warning] one-liner body
```

→ `<blockquote class="sx-alert sx-alert-warning">\n<p
class="sx-alert-title">Warning</p>\n<p>one-liner body</p>\n</blockquote>`

Degradation: `> [!IDEA] hm` is a plain blockquote containing the literal
text `[!IDEA] hm`; `> before [!NOTE]` never activates (not first).

## Future direction

- More types only by extending the one enum + its styling — but each
  addition changes the meaning of existing literal text, so additions come
  through a note.
- Per-type icons and collapsible alerts (Obsidian's `[!note]-`) are
  deliberately out; collapsing belongs to `collapse()` (note 007).
- A custom-title form (`> [!NOTE] Title:` …) is not defined.
