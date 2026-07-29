# Cross-document links

A relative link ending in `.md` or `.sx` is a **cross-document link**: strike
resolves it to the target's route, and every other markdown tool treats it as
an ordinary file link. One spelling works in both worlds.

// links grid(2)

**From this folder**

. [This folder's page](main.md) — a `main.*` target lands on the folder route
. [Sibling by name](cross-links.md) — itself

// --

**Up a level**

. [The site's front page](../main.md)
. [The markdown subset](../markdown.md)
. [A specific section](../markdown.md#tables) — fragments survive

// end links

## What gets rewritten

Only *relative* targets ending in `.md`/`.sx`. Everything else passes through
untouched:

| Target | Result |
| --- | --- |
| `../markdown.md` | rewritten to the document's route |
| `../markdown.md#tables` | rewritten, fragment preserved |
| `/absolute/path` | untouched |
| `https://ziglang.org` | untouched |
| `#a-fragment` | untouched |
| `diagram.png` | untouched — assets stay content-relative |

  Resolution happens against the linking document's own directory, so `../`
  climbs exactly the way it does on disk. The extension is dropped and a
  trailing `main` collapses into its folder's route, which is why the first
  link on this page points at the folder rather than a page called "main".
