# The markdown subset

Everything on this page is ordinary markdown, and this file is the one page in
the tour still named `.md` — every other page is `.sx`. Both go through the same
parser and the same renderer. That is the whole of the "one flavor" claim, and
you are looking at the proof: nothing here is doing anything special, and
nothing here is missing anything the `.sx` pages have.

This page covers the *rules* that surprise people. For a dense look at every
form at once, read [the gallery](gallery.sx).

## Headings and anchors

Every heading gets an anchor id slugified from its text — lowercased, runs of
punctuation and spaces collapsed to `-` — and deduplicated within the document,
so [links to a section](#lists) work. Non-ASCII characters survive as written
rather than collapsing away, so a heading in any script still gets a usable id.

## Text

*Italic*, **bold**, ***both***, ~~struck~~, `inline code`, and a backslash
escape for when you want a literal \*asterisk\*.

Emphasis delimiters have to hug their content — CommonMark's flanking rule — so
ordinary prose survives: `a * b * c` and `5 * 4 * 3` render as the asterisks you
typed. A delimiter that cannot close is skipped rather than fatal, so `*a * b*`
is one emphasis containing an asterisk.

Soft-wrapped lines join into one paragraph, and a span may open on one line
and *close on
a later one*. Inline syntax reads the joined paragraph, not the source line.

  A paragraph that starts with whitespace is indented one step. Two spaces,
  four spaces, or a tab all mean the same thing — one step. This second line
  is just a continuation, so it stays flush.

Underscores are *not* emphasis here: `_this_` stays literal. So do hard line
breaks, `~~~` fences, `1)` ordered markers, setext headings, footnotes, and
front matter — all still-open gaps rather than decisions.

## Lists

- unordered
- lists
  - nest by indentation
    - as deep as you like

An ordered list starts at its first written number and ignores the rest:

1. ordered lists
2. start at their first written number
7. and this renders as 3

A blank line does **not** end a list — a marker that could continue it simply
continues it. Only something that is not a continuation ends it, like this
paragraph, which is why the next list starts fresh:

5. so this one really does start at five
6. and counts on from there

- [ ] task boxes
- [x] that render as checkboxes

. a raw list
. drops the marker entirely
. while staying a list

## Quotes and alerts

> A blockquote. Consecutive `>` lines flow into one paragraph.
>
> A bare `>` line starts a second one.
A plain line right after a quote line lazily continues it.

A blockquote holds flowing paragraphs and nothing else. A list, heading, or
fence written inside one is literal text in the quote — worth knowing before you
try to nest.

Alerts are typed blockquotes — a `[!TYPE]` marker on the first line, one of
eight types ([all eight are in the gallery](gallery.sx#alerts)):

> [!NOTE]
> Something worth knowing, in passing.

> [!WARNING] The body can also start on the marker's own line — a superset
> convenience; GFM wants the marker alone.

An unrecognized type is not a marker at all: `> [!IDEA] hm` is a plain
blockquote with literal text.

## Rules and code

Three or more `-`, `*`, or `_` on a line of their own draw a rule. They have to
be unbroken — GFM's spaced `- - -` is a list item here, not a rule.

---

```zig
pub fn main() !void {
    std.debug.print("fenced code keeps its language\n", .{});
}
```

Code bodies are verbatim — no inline parsing happens inside, and the info string
past the first token is ignored. There is no four-space indented code block:
leading whitespace on a paragraph means [indentation](commands.sx#indent).

## Tables

| Command | Argument | Default |
| --- | :-: | ---: |
| `grid` | column count | — |
| `skinny` | percentage | 75% |
| `wide` | percentage | 125% |

Alignment comes from the separator row: `:-:` centers, `--:` right-aligns. A
`\|` puts a literal pipe inside a cell.

## Math

Inline math like $e^{i\pi} + 1 = 0$ passes through to MathJax, and display
math gets its own block:

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

Dollar signs in prose are safe: the book costs $5 and the pen costs $10, and
$HOME and $PATH are still environment variables. Math needs a non-space right
after the opening `$`, a non-space before the closing one, and no digit after
it.

## Links and images

An [inline link](https://ziglang.org), an autolink <https://ziglang.org>, and
a bare URL: https://ziglang.org — trailing sentence punctuation stays out of
the link, so that period is not part of it.

A [link to another document](groups.sx) resolves to its route here, and stays
a working file link on GitHub. That is the one piece of this page that behaves
differently depending on who is rendering it, and it degrades in the direction
that keeps working.

Images use the same syntax with a leading `!`, and their targets are left
content-relative — `logo.svg` sits next to this file on disk, and `strike serve`
hands it out from there:

![the strike logo](logo.svg)
