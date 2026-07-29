# The markdown subset

Everything on this page is ordinary markdown. It renders the same here as it
does anywhere else — that is the whole point of the subset rule.

## Headings and anchors

Every heading gets an anchor id slugified from its text, deduplicated within
the document, so [links to a section](#lists-of-every-kind) work.

## Text

*Italic*, **bold**, ***both***, ~~struck~~, `inline code`, and a backslash
escape for when you want a literal \*asterisk\*.

Emphasis delimiters have to hug their content, so prose survives: `a * b * c`
and `5 * 4 * 3` render as the asterisks you typed, not as emphasis.

Soft-wrapped lines join into one paragraph, and a span may open on one line
and *close on
a later one*.

  A paragraph that starts with whitespace is indented one step. Two spaces,
  four spaces, or a tab all mean the same thing — one step. This second line
  is just a continuation, so it stays flush.

## Lists of every kind

- unordered
- lists
  - nest by indentation
    - as deep as you like

1. ordered lists
2. start at their first written number
7. and ignore the rest

5. this one starts at five

- [ ] task boxes
- [x] that render as checkboxes

. a raw list
. drops the marker entirely
. while staying a list

## Quotes and alerts

> A blockquote. Consecutive `>` lines flow into one paragraph.
>
> A bare `>` line starts a second one.

> [!NOTE]
> Alerts are typed blockquotes: NOTE, TIP, IMPORTANT, WARNING, CAUTION, plus
> TODO, EXAMPLE and QUESTION.

> [!WARNING] The body can also start on the marker's own line.

## Code

```zig
pub fn main() !void {
    std.debug.print("fenced code keeps its language\n", .{});
}
```

Indented or not, code bodies are verbatim — no inline parsing happens inside.

## Tables

| Command | Argument | Default |
| --- | :-: | ---: |
| `grid` | column count | — |
| `skinny` | percentage | 75% |
| `wide` | percentage | 125% |

Alignment comes from the separator row: `:-:` centers, `--:` right-aligns.

## Math

Inline math like $e^{i\pi} + 1 = 0$ passes through to MathJax, and display
math gets its own block:

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

Dollar signs in prose are safe: the book costs $5 and the pen costs $10, and
$HOME and $PATH are still environment variables.

## Links and images

An [inline link](https://ziglang.org), an autolink <https://ziglang.org>, and
a bare URL: https://ziglang.org

A [link to another document](layout.md) resolves to its route here, and stays
a working file link on GitHub.
