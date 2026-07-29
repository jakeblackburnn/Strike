# Guide

This folder has a `main.md`, so the folder itself has a page — this one — and
its nav label is a link rather than a plain heading. Files named `main.md` or
`main.sx` never appear in the nav; they *become* the page at their containing
folder's route.

The same convention works at three levels:

| Where `main.*` sits | What it becomes |
| --- | --- |
| the content root | the site's front page (`/`) |
| a project root | that project's home (`/<project>`) |
| any subfolder | the folder's own page |

## Organizing content

A content folder is scanned automatically: `.md`/`.sx` files are documents,
subfolders nest into the nav. Nothing needs configuring.

  When you do want control, `strike.yaml` supplies it — labels, ordering,
  hidden paths, the theme, and serve defaults. This folder inherits the site
  config one level up; a `strike.yaml` here would layer on top of it.

> [!NOTE]
> Loose documents at the content root put the whole tree into **root-project
> mode**, which is what this example uses: `/` is the root `main.md` and this
> folder nests inside it. A root with only subfolders gets a project picker
> at `/` instead.

Next: [cross-document links](cross-links.md).
