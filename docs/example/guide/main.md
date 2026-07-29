# Guide

This folder has a `main.md`, so the folder itself has a page — this one — and
its nav label is a link rather than a plain heading. Files named `main.md` or
`main.sx` never appear in the nav; they *become* the page at their containing
folder's route.

The same convention works at three levels:

| Where `main.*` sits | What it becomes |
| --- | --- |
| the content root | the front page at `/` — the picker's intro, or the root project's home |
| a project root | that project's home (`/<project>`) |
| any subfolder | the folder's own page |

## Organizing content

A content folder is scanned automatically: `.md`/`.sx` files are documents,
subfolders nest into the nav. Nothing needs configuring.

  When you do want control, `strike.yaml` supplies it — labels, ordering,
  hidden paths, the theme, and serve defaults. Configuration lives at exactly
  two scopes: the content root (site-wide) and a project root (that project's
  nav). A `strike.yaml` in a subfolder like this one is **not** read — it is
  skipped by the scan like any other non-document file.

So this folder is configured from `../strike.yaml`, one level up, using
project-relative paths:

```yaml
labels:
  guide: Guide                  # a folder gets a label like any document
hidden:
  - guide/scratch.md            # dropped from the nav AND from the routes
```

`scratch.md` really is in this folder on disk. It has no nav entry and its route
404s — which is how a working file lives beside published ones.

> [!NOTE]
> A content root holding only folders becomes a **project picker** at `/`, which
> is what this site does: `docs/` picks between this tour and the reference docs.
> A root with loose documents beside its folders goes the other way — the whole
> tree becomes one **root project** served at `/`, subfolders nesting into its
> nav, which is how a repo's `docs/` folder works with no config at all.

Next: [cross-document links](cross-links.md).
