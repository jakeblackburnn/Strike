# NNN — Feature name (`syntax sketch`)

**Status: draft** <!-- draft | accepted (decision dictated by <who>, <date>) |
shipped (<date>) | rejected/superseded (<why, one line>) -->

<!-- Copy this file to docs/design/NNN-slug.md (next number, never reused).
     The lifecycle and division of labor are governed by docs/DESIGN.md:
     the AI diverges (candidates, analysis), the human dictates the Decision;
     nothing is implemented from a draft. Notes are history once shipped —
     docs/STRIKEDOWN.md is the spec of record. -->

## Problem

What the language cannot express today, and why that matters. One paragraph.

## Terminology

New terms this note introduces, each defined in one line. Omit the section if
there are none. Terms promoted into the spec must keep these meanings.

## Candidates

2–3 genuinely different syntaxes, each with a worked example. Alternatives to
choose between, not one proposal to approve.

### A — `<syntax>`

```
worked example
```

Consequences, edge cases, how it reads in real documents.

### B — `<syntax>`

…

## Degradation analysis (mandatory)

For each candidate: what happens in a document that never activates the form?
Every superset form must be inert prose there. Include the **corpus check** —
grep `strikedown/` for lines the new trigger would accidentally activate, and
name what was found (or "zero hits").

## Decision

Dictated by the human. Names the chosen candidate and pins every semantic the
implementation needs. Empty in a draft.

## Canonical examples

Input/output pairs that become tests verbatim: a parser test in
`src/strikedown.zig` and an end-to-end test in `src/render_html.zig` each.
Include at least one degradation example.

## Future direction

What this deliberately leaves open, and the shape extensions should take.
