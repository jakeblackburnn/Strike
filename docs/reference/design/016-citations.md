# 016 — Citations (`[text].cite(refs)` + `// citations()`)

**Status: shipped** (decided 2026-08-03, implemented 2026-08-03). The shape in
candidate A came out of a 2026-08-02 brainstorm; the Decision section below
records what was chosen from it and from the open questions.

## Problem

Strikedown cannot express a citation. A document can link and it can quote, but
it cannot say *this claim comes from that source* and have the renderer number
the mark, anchor the entry, and set the reference list as a bibliography. That
gap is tolerable for the reader and fatal for the roadmap's second backend:
PDF exists in the plan for "articles/academic papers with excellent
professional typography", and an academic paper without citations is not a
paper. Footnotes are a separate, already-declared spec gap (GFM is their spec,
no note required) and do not close this one — a footnote is an aside, a
citation is an attribution with a bibliography behind it.

## Terminology

- **Mark** — the inline thing you write where you cite; what the reader sees as
  `[1]`, `(Knuth 1984)`, or a superscript.
- **Entry** — one item in the reference list.
- **Bibliography** — the rendered list of entries.
- **Locator** — the page/chapter narrowing a mark ("p. 91").
- **Binding** — how a mark names its entry (positionally, or by key).

## Prior art

Recorded because the deliberate departure in candidate A only makes sense
against it.

- **GFM footnotes** — `[^id]` inline, `[^id]: text` in block position.
  Identifiers are arbitrary labels; the numbers the reader sees come from
  **order of first appearance**, not the label. Definitions may appear
  anywhere and always render collected at the end; repeat references dedup to
  one note with several backlinks. Pandoc adds inline footnotes `^[text]`,
  which need no label at all.
- **Pandoc + CSL** — the academic de facto standard (Quarto, R Markdown,
  Zotero export, Obsidian plugins all speak it). `[@key]` parenthetical,
  `@key` narrative, `[-@key]` author-suppressed, `[see @key, pp. 33-35;
  @other]` with a recognized locator vocabulary (`p.`, `chap.`, `sec.`, …).
  Data comes from a `bibliography:` key naming `.bib` / CSL-JSON / CSL-YAML.
  Rendering is delegated wholesale to **CSL** — ~2500 XML style files, and a
  large language of its own to implement.
- **BibTeX/biblatex** — `@book{key, author = {…}, …}`. Forty years of inertia:
  every reference manager exports it. Its *mark* syntax (`\cite`, natbib's
  `\citep`/`\citet`) is not worth copying; Pandoc says the same thing with
  less.
- **Typst** — the closest analogue to strike (typography-first, plain text,
  PDF-native, from scratch). Took bare `@key` as primary (it can — `@` is not
  otherwise meaningful in its markup, unlike prose markdown), kept a verbose
  `#cite()` for the argument cases, reads `.bib` natively, and ships a dozen
  built-in styles with CSL as an *escape hatch* rather than the foundation.

The common inheritance in all four: **entries live in a separate, structured,
non-prose file**. That is a 1985 constraint, not a requirement.

## Candidates

### A — inline span + a `citations()` group *(the brainstorm shape)*

```
// citations()

1. D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
2. L. Lamport, *LaTeX: A Document Preparation System*, 1986.

//
```

```
[Line-breaking is best solved as a dynamic program].cite(1) — a result
that predates the typesetting system it was written for.
```

Two halves, each reusing machinery that exists:

- The **mark** is the established `[text].command(args)` inline postfix — the
  same grammar as the color span — so it inherits those mechanics unchanged:
  the link form wins the `[` (`[label](url).cite(1)` is a link followed by
  prose), spans do not nest, the postfix must follow the `]` immediately, and
  a malformed argument leaves the whole thing literal.
- The **bibliography** is a group carrying a new **structural** command, in
  the shape `collapse()` already established: it shapes the emitted elements
  rather than styling them (`Attrs.anyStyle` skips it), it counts under the
  layout-level rule (citations inside citations strips and warns), and it
  arrives through the normal recipe — `Command` variant, `applyCommand` arm,
  the exhaustive `isLayout`/`isStructural`/`hasCommand`/`clearCommand` arms,
  an emitter reading the field.

The departure worth stating plainly, because it is the reason to prefer this
shape over adopting Pandoc's: **the entries are ordinary content.** A numbered
list with full inline markup — italic titles, links, math — written and
ordered by the author. `citations()` does not define a data format; it
declares what an already-written list *is*. What the command then buys,
emitter-side, is exactly the part markdown tools do badly: entries become
anchor targets, marks resolve and link to them, entries back-link to their
citation sites, and the list is set in bibliography form (hanging indent,
tightened leading, numbers in the margin).

The second departure is semantic, and is either the design's best idea or its
biggest liability: **a citation here is a span, not a point.** Pandoc, LaTeX,
and Typst all insert a mark *between words*; this form attaches the source to
the run of text making the claim. That is more honest about what a citation
asserts, and it gives the reader affordances nothing else has (the span is the
hover target for the entry; it highlights when the reader jumps back from the
bibliography). It costs the point-citation case — see "Open questions".

**Binding** in the sketch is *positional*: `.cite(3)` means the third entry,
and the numbers the reader sees are the ids. Nothing to look up, author
controls order absolutely. It costs reordering (renumber every mark),
author-date styles, and cross-document reuse. A key-carrying entry form is
sketched under "Open questions"; note that all-digit and name-shaped arguments
are disjoint by grammar — the same trick `skinny`/`wide` use — so keys can be
added later without invalidating a document.

### B — adopt Pandoc's marks (`[@key]` / `@key`)

```
The algorithm [@knuth1984] is standard; as @lamport1986 later showed, …
```

Entries come from a `.bib` or CSL-JSON file named by `strike.yaml`, resolved
in `project.zig` and handed to `parse` as a parameter beside `base_sheet` —
structurally identical to how `header:` resolves a `Sheet`, so `parse` stays
pure and a project gets one shared bibliography free.

The case for it is interoperability: this is the syntax academics already
type and the format every reference manager already exports, so a user with a
Zotero library is productive immediately. The case against is that it imports
a second content-naming key into `strike.yaml` (today `header:` is the *only*
sanctioned crossing of the language/toolkit line, and `DESIGN.md` says so
explicitly), it makes the bibliography a foreign format strikedown cannot
style, and rendering marks properly means either shipping hardcoded styles
anyway or implementing CSL.

Bare `@key` should probably be rejected regardless of the rest: `@` is live in
prose (handles, emails) in a way it is not in Typst's markup.

### C — footnotes only

Implement GFM footnotes (`[^id]`, `[^id]: …`) plus Pandoc's inline `^[…]`, and
let citation be a convention rather than a feature.

```
Knuth's algorithm[^tex] is standard.

[^tex]: D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
```

Requires **no design note at all** — footnotes are a declared standard-markdown
gap, GFM is their spec. Cheapest by an order of magnitude, and it builds the
collect/dedup/number-by-appearance machinery any citation system needs anyway.
It is genuinely sufficient for essays. It is not sufficient for papers: no
sorted bibliography, no bibliography typography, no author-date, no reuse
across documents.

C is not exclusive with A or B. It is plausibly the right *first* step under
any decision, and the three-way choice is really "C alone" vs "C then A" vs
"C then B".

## Degradation analysis (mandatory)

**A — mark.** `[text].cite(1)` today is a shortcut reference link (unimplemented)
followed by literal text, so it renders as visible prose, exactly as the color
span did before activation. An older strike renders a newer document's citation
as readable text, never as broken output.

**A — group.** The strongest degradation story of any candidate: an older
strike does not recognize `citations()`, the whole `//` line therefore fails
the parses-cleanly rule and reverts to prose, and **the reference list still
renders — as a correctly ordered numbered list.** Nothing is lost but the
linking and the bibliography setting.

**B.** `[@knuth1984]` is likewise a shortcut-reference-shaped literal today, so
it degrades to visible prose of comparable noise. Bare `@key` does not degrade
— it is already meaningful-looking prose, and activating it changes existing
documents. The `.bib` file degrades to nothing at all (an older strike ignores
the yaml key and the marks render literal, with no entries anywhere).

**C.** GFM behavior is the spec; an unrecognizing renderer shows `[^tex]` and
the definition line as prose.

**Corpus check (2026-08-02, over `docs/`):**

- `].cite(` — **zero hits**. `.cite(` anywhere — zero hits.
- `//` lines mentioning citations — zero hits.
- `[^` (footnote refs) — zero hits.
- List items beginning `[word]` (the key-form trigger sketched below) — 4
  hits, *all* of them either a markdown link (`. [Degradation](degradation.md)`)
  or a task box (`- [x] that render as checkboxes`). Both forms already win
  the bracket ahead of any new rule, so a key form would need to be specified
  to lose to links and task boxes — but no *real* collision exists in the
  corpus.

## Open questions

Every one of these is undecided. They are listed in rough order of how much
the rest depends on them.

1. **Does the language get citations at all, or just footnotes?** (C alone vs
   C-then-A vs C-then-B.) Nothing else matters until this is answered.
2. **Span-only, or is there a point form?** If a bare mark is wanted, the
   options are `[].cite(1)` (empty brackets; parses cleanly, no new grammar,
   ugly), a bare inline `.cite(1)` (narrow trigger, but the first inline form
   that is not bracket-anchored — wants its own corpus check), or a decision
   that span-only is deliberate and you mark what you cite.
3. **Positional ids or keys?** Positional (`cite(3)` → third entry) is
   simplest and is what the sketch shows. Keys need an entry form; the
   candidate is a leading `[key]` on the entry —

   ```
   1. [knuth1984] D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
   ```

   — which would be far too weak a trigger globally, but is safe *inside* a
   declared `citations()` group. That introduces **context-scoped parsing**,
   which strikedown does not do today (group content parses identically to
   everything else); the novelty, not the ambiguity, is the real cost. The
   middle path is positional now, keys later, since the two argument shapes
   are disjoint by grammar.
4. **Multiple sources on one mark.** `[…].cite(1, 4)` needs a multi-argument
   command; no command takes more than one argument today.
5. **Locators.** This design has a free answer Pandoc had to build a
   vocabulary for — put it in the visible text (`[Knuth's analysis, p.
   91].cite(1)`). Is that sufficient, or does the mark need structure?
6. **Command or reserved group name?** `// citations()` (a command, per the
   recipe) vs `// citations` (a reserved bare name, like `end` and `--`). The
   command form is more machinery but far more regular.
7. **How many citations groups per document?** One, with a warning on the
   second, is the simple rule; per-section bibliographies are real in books,
   and the layout-level rule already permits sibling groups. If more than one
   is legal, marks need a binding rule (nearest preceding? nearest
   following?).
8. **Numbering authority.** With positional binding the author's list order
   *is* the numbering, which is honest and simple. Order-of-first-appearance
   numbering (GFM's footnote rule) would mean the renderer reorders content
   the author wrote — probably wrong here, but it is the difference between
   numeric and author-date styles and should be decided, not defaulted into.
9. **Rendering style as config.** "strike owns rendering style" suggests a
   `strike.yaml` key selecting among a few hardcoded styles (numeric,
   author-date), with CSL as a possible later escape hatch — the Typst
   posture, not the Pandoc one. Not decided, and not blocking.
10. **Project-wide reuse.** If a bibliography should be shared across a
    project's documents, the shape that fits is a `// citations()` block in a
    file loaded the way `.sxh` headers are (still strikedown, still content,
    `parse` still pure) — as against B's `.bib`. Deliberately deferred.
11. **PDF.** This design is inherently an endnote/bibliography model: the
    group renders where it is written. Footnotes at page bottoms are a
    different feature (C), and the two are complementary.

## Decision

Dictated 2026-08-03. **Candidate A ships**, resolving the open questions as
follows:

1. *Scope (Q1)*: A — the `[text].cite(refs)` span plus the `// citations()`
   group. Footnotes (C) remain a separate, complementary spec gap.
2. *Point form (Q2)*: **span-only for now**; a bare point-citation form may be
   added later. The span is the point: the entire cited claim is the hover and
   click target — "more of a flexible footnote system." A future point form
   would make just the mark clickable. `[].cite(…)` stays unparsed (literal
   prose) to keep that space unclaimed.
3. *Binding (Q3)*: **mixed** — entries may open with a leading `[key]` but
   don't have to; marks cite by key or by number, both resolving to the same
   numbered entries. The citations group must contain a numbered list — the
   entries. Key lifting happens only inside the declared group (the first
   context-scoped form, implemented as a parse-end pass, not context threaded
   into line parsing).
4. *Multiple sources (Q4)*: yes — `.cite(1, 4)`, a comma-separated ref list,
   the first multi-argument command grammar (contained entirely inside
   `cite`'s own argument parsing).
5. *Locators (Q5)*: in the visible text; the mark carries no structure.
6. *Command vs name (Q6)*: **command** — `// citations()`, structural, per the
   `collapse` recipe.
7. *Group count (Q7)*: **one per document** for now (extras degrade to plain
   groups with a warning); may be relaxed in future versions.
8. *Numbering authority (Q8)*: the author's list order *is* the numbering —
   positions are 1-based item indices; key refs display as the number of the
   entry they name.
9. *Style config (Q9), project-wide reuse (Q10), PDF page-bottom notes (Q11)*:
   deferred, per Future direction.

Rendering (strike's side, iterative, not language spec): the span is unstyled
at rest and subtly emphasized on hover; a superscript number follows it; span
and number both link to the entry; hovering previews the entry (plain-texted,
via `title`); entries back-link to every citing mark.

## Canonical examples

```
[Line-breaking is best solved as a dynamic program].cite(1) — a result that
predates the system it was written for.

// citations()

1. D. Knuth, *The TeXbook*, Addison-Wesley, 1984.

//
```

→ the span carries a mark resolving to the first entry; the entry anchors it
and links back; the list is set as a bibliography.

```
[Both systems agree on the optimum].cite(knuth1984, 2)

// citations()

1. [knuth1984] D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
2. L. Lamport, *LaTeX: A Document Preparation System*, 1986.

//
```

→ one mark, two sources: the key names the first entry, the number the
second; the reader sees the numbers (`1,2`). The `[knuth1984]` prefix is
lifted from the rendered entry.

Degradation: rendered by a strike that does not know `cite`, the same document
shows the bracketed text and `.cite(1)` as prose, and the reference list as an
ordinary numbered list — readable, correctly ordered, unlinked (the key
prefixes visible as bracketed text).

## Future direction

- **Footnotes (C) are complementary, not competing** — asides want page-bottom
  notes; citations want a bibliography. Landing C first builds shared
  machinery under either decision.
- **Keys, if positional binding ships first**, arrive without breaking
  documents (digits vs names are disjoint).
- **Aliases (note 010)** would let a project name a citation vocabulary once
  the `:` namespace reopens.
- **Sheet → CSS compilation** (roadmap) applies here as everywhere: a
  bibliography's hanging indent belongs in a stylesheet rule, not repeated
  inline styles.
