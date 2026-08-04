# Reference

The documents of record for strikedown (the language) and strike (the toolkit).
This file is the project's `main.md`, so it is the page you land on at
`/reference` — it never appears in the nav beside the documents it introduces.

// map grid(2)

**The language**

. [strikedown](STRIKEDOWN.md) — the spec: every block form, every inline form,
  every command, and the degradation rules that keep plain markdown plain
. [strike.yaml](STRIKE_YAML.md) — the config reference: scopes, keys, and how
  values resolve

// --

**The implementation**

. [The internal model](MODEL.md) — the document tree, the two-stage pipeline,
  and the taxonomy each type maps onto
. [Reader UI](UI.md) — the principles the reader chrome is designed against

// end map

## How changes get made

A language change starts as a design note, not a patch. [DESIGN.md](DESIGN.md)
describes that process; [design/](design/000-template.md) is the archive — one
note per feature, each recording the candidates that were considered and the
decision that was taken. Reading a note tells you *why* a form looks the way it
does, which the spec deliberately doesn't say.

> [!NOTE]
> The spec wins. Where a design note and [STRIKEDOWN.md](STRIKEDOWN.md)
> disagree, the note is history and the spec is current — notes are written
> before a feature ships and are not revised afterwards. The one exception is a
> note marked **living**, which stays open because it is where a whole class of
> decisions gets made one at a time.

## Elsewhere

The [example project](../example/main.sx) is the same material as running code:
a working site where every language feature appears in a document you can read
in the browser and open in your editor side by side.
