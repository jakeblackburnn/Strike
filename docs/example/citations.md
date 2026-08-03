# Citations

A document cites in two halves: an inline **mark** attaches a source to the
text making a claim, and one `citations()` group declares which list holds
the sources. This page is its own demo — every mark below resolves into the
bibliography at the bottom.

## Marks — `[text].cite(refs)`

The mark is a span, not a point between words: you mark **what you cite**.
[Line-breaking is best solved as a dynamic program].cite(1) — hover that
claim to preview its source, click it (or the number) to jump to the entry,
and follow the entry's ↩ back here.

Refs can be **numbers** (the entry's position in the list) or **keys**, and
one mark can carry several: [both the original analysis and its later
restatement agree].cite(1, lamport86). Page numbers and other locators just
live in the text you mark — [the proof in chapter three, p. 91].cite(texbook)
needs no special syntax for "p. 91".

## Entries are ordinary content

The bibliography below is a plain numbered list — full inline markup,
written and ordered by you. The numbers readers see *are* your list order.
An entry may open with a `[key]` prefix to name itself; the prefix is
lifted from the rendered page, and all-digit brackets stay literal prose,
so keys can never collide with positions.

A mark that resolves nowhere — an unknown key, a number past the end —
warns on stderr and renders inert, and in a renderer that predates the
feature entirely, every mark above reads as prose and the list below is
still a correctly ordered reference list. That degradation is the design.

## References

// citations()

1. [texbook] D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
2. [lamport86] L. Lamport, *LaTeX: A Document Preparation System*,
   Addison-Wesley, 1986.
3. An entry nobody cites — it still anchors, it just has no backlinks.

//
