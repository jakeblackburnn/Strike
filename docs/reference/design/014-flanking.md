# 014 — Flanking rules for emphasis and inline math

**Status: shipped** (decision dictated by Jack, 2026-07-29)

## Problem

Two inline forms fire on ordinary prose, which breaks the language's central
promise: a plain-markdown document must render unchanged. Emphasis pairs any
`*` with the next `*`, and inline math pairs any `$` with the next `$`, with no
regard for what surrounds the delimiter. So `a * b * c` emphasizes a space, `5 *
4 * 3` italicizes a multiplication, `The book costs $5 and the pen costs $10`
typesets the middle of the sentence as TeX, and `$HOME` / `$PATH` in a prose
line about shell variables does the same. None of these documents ever opted
into a superset feature; they are markdown, and they render wrong.

The gap is that strike has no notion of a delimiter's *context*. CommonMark
solved this for emphasis with left- and right-flanking delimiter runs, and
GitHub solved it for `$…$` math with three small adjacency rules. Neither is
implemented here.

## Terminology

- **Delimiter run** — a maximal sequence of the same delimiter character
  (`*`, `~`) at one position; `***` is one run of three.
- **Left-flanking** / **right-flanking** — a run's eligibility to *open* /
  *close* a span, decided by the characters immediately before and after it
  (CommonMark's definition, quoted in full under Decision).

## Candidates

### A — Full CommonMark flanking

Adopt CommonMark's definitions verbatim for every emphasis delimiter, and
GitHub's adjacency rules for inline math.

```
a * b * c        →  literal asterisks
5 * 4 * 3        →  literal asterisks
**"quoted"**     →  bold (the punctuation clause allows it)
intra*word*em    →  emphasis
costs $5 and $10 →  literal dollars
$x^2$            →  math
```

The rules are ~15 lines of helpers and, more importantly, already *exist*: the
spec can cite a definition readers can look up rather than inventing a
strike-only dialect. The punctuation clauses are what let `**"quoted"**` and
`*(parenthetical)*` keep working — a whitespace-only rule handles those by
accident, not by design, and the two diverge on cases like `a*"b"*c`.

Cost: the definitions are genuinely fiddly to read, and a reader who wants to
know why one line emphasized and another didn't has to reason about four
clauses.

### B — Whitespace-only adjacency

A simpler house rule: an opener must not be followed by whitespace, a closer
must not be preceded by whitespace.

```
a * b * c        →  literal asterisks
5 * 4 * 3        →  literal asterisks
**"quoted"**     →  bold
a*"b"*c          →  differs from CommonMark
```

Two clauses instead of four, explainable in one sentence, and it fixes every
real case in the corpus. Cost: it is a strike-specific rule that agrees with
CommonMark today and drifts from it at the punctuation edges — exactly the kind
of quiet divergence "plain markdown is the subset" is meant to preclude. Every
future edge case becomes a fresh judgment call instead of a lookup.

### C — Leave emphasis, fix only math

Inline math is a superset form, so arguably only it must degrade; `*` behavior
is inherited from the markdown subset and could stay as-is.

Rejected on its face: the subset promise cuts the other way. `5 * 4 * 3`
rendering as emphasis is wrong *as markdown*, independent of any superset
concern, and "we match markdown except where we don't" is not a spec.

## Degradation analysis (mandatory)

Both changes move strictly in the safe direction: they make *more* text inert
prose. No document gains meaning; some documents lose meaning they never asked
for. A document that renders correctly today either renders identically or
loses a false positive.

**Corpus check** — run against every `.md`/`.sx` in `strikedown/`, with fenced
code and display math excluded:

| Form | Occurrences | Changed by the new rules |
| --- | --- | --- |
| inline `$…$` | 1173 pairs | **0 real math spans break.** 7 spans change, every one of them money text that is broken today: `$130K \| $`, `$110K \| $`, `$5. You win $`, `$10 concert ticket, 50% chance of a $` |
| `*…*` emphasis | 168 pairs | **1 changes**: `* $X$ *` in `topo/homeomorphism.md` — itself a false positive (a bullet-shaped line, not emphasis) |

Zero legitimate spans regress across 1341 real occurrences, and every span the
rules do touch is one that is wrong today. This is the strongest corpus result
of any note so far, which is what makes shipping the strict variant safe.

## Decision

**Candidate A.** Full CommonMark flanking for emphasis, GitHub's adjacency
rules for inline math. The language does not invent delimiter semantics when a
specified definition exists; a reader can look up the rule, and future edge
cases resolve by reference rather than by judgment.

Emphasis — a delimiter run may **open** a span only if it is left-flanking, and
may **close** one only if it is right-flanking. Both terms are defined against
the *joined* text of a flowing element (see MODEL.md), and the start and end of
that text count as whitespace:

- **left-flanking**: the run is not followed by whitespace, AND either it is
  not followed by punctuation, or it is followed by punctuation and preceded by
  whitespace or punctuation.
- **right-flanking**: the run is not preceded by whitespace, AND either it is
  not preceded by punctuation, or it is preceded by punctuation and followed by
  whitespace or punctuation.

This applies uniformly to `***`, `**`, `*`, and `~~`. When the nearest
candidate closer is not right-flanking, the scan continues to the next one
rather than giving up — `*a * b*` is one emphasis containing a lone asterisk.
Strike has no `_` emphasis, so `snake_case` and `__init__` need no special
casing; they were already inert and stay inert.

Inline math — a `$…$` span requires all four:

1. the opening `$` is followed by a non-whitespace character,
2. the closing `$` is preceded by a non-whitespace character,
3. the closing `$` is not immediately followed by an ASCII digit,
4. the body is non-empty.

Rule 3 is what makes `costs $5 and $10` prose: the only candidate closer is the
`$` before `10`, and a digit follows it. As with emphasis, a non-qualifying
candidate is skipped, not fatal. `\$` escaping is unchanged, and `$$` display
math is a block form these rules never see.

## Canonical examples

```
a * b * c                              →  a * b * c            (literal)
5 * 4 * 3                              →  5 * 4 * 3            (literal)
*emphasis*                             →  <em>emphasis</em>
**"quoted"**                           →  <strong>"quoted"</strong>
intra*word*em                          →  intra<em>word</em>em
*a * b*                                →  <em>a * b</em>
~~ not strike ~~                       →  ~~ not strike ~~     (literal)
~~struck~~                             →  <del>struck</del>
The book costs $5 and the pen is $10.  →  literal dollars
$HOME and $PATH are set                →  literal dollars
$x^2$                                  →  \(x^2\)
$ x $                                  →  literal dollars
```

## Future direction

The delimiter scan stays a single left-to-right pass with local lookaround; it
is deliberately not CommonMark's full delimiter-stack algorithm, which exists to
resolve pathological nesting (`*a **b* c**`) that no real document writes. If
such a case ever matters, the growth path is a proper stack in the inline
chain — the flanking predicates written here are exactly what that algorithm
consumes, so they carry over unchanged.

Underscore emphasis, if it is ever added, inherits these predicates plus
CommonMark's extra intraword restriction (`_` may not open or close inside a
word), which is the whole reason `snake_case` is safe in every other renderer.
