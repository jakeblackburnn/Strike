# Kitchen sink

Every form `base_md` implements, once each. This is deliberately small — see
`dev/terms.md` for everything left out and why.

## Headings

Headings go up to level six, though this file stops at two for brevity.

## Paragraphs and inline text

A paragraph can soft-wrap across
several source lines and still joins into one flowing element, so a span
can *open on one line
and close on the next*.

Inline forms: `code spans`, **strong text**, *emphasis*, and nesting like
**strong with *emphasis* inside it**.

## Code

A fenced block with a language tag:

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("kitchen sink\n", .{});
}
```

And one with no language tag at all:

```
plain verbatim text, never inline-parsed: *not italic*
```
