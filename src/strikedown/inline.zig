//! Inline-span parsing: table cell splitting, `[text](url)` links,
//! `.color`/`.cite` postfix spans, autolinks, and the emphasis/strikethrough
//! chain with its CommonMark flanking rules (`docs/reference/design/014-flanking.md`).
//! All free functions over `[]const u8`/`Allocator` — no parser state. Split
//! out of `strikedown.zig`; `isTableStart`/`isTableSeparator` stay there
//! since they need the block-classifier helpers (`isBlockStart` etc).

const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

const Align = model.Align;
const Inline = model.Inline;
const TextColor = model.TextColor;
const CiteRef = model.CiteRef;

/// Strip at most one leading and one trailing boundary pipe. Separator rows
/// only — they can hold nothing but `-`, `:`, `|` and spaces, so there are no
/// escapes to worry about here; `splitCells` handles its own boundaries.
pub fn stripBoundaryPipes(s: []const u8) []const u8 {
    var r = s;
    if (r.len > 0 and r[0] == '|') r = r[1..];
    if (r.len > 0 and r[r.len - 1] == '|') r = r[0 .. r.len - 1];
    return r;
}

/// Split a table row into trimmed cells at every unescaped `|`.
///
/// GFM splits cells *before* parsing inlines, so a pipe that is part of a
/// cell's content must be written `\|` — including inside a code span, whose
/// body is never inline-parsed afterwards. That makes this the only place the
/// escape can be undone, so `\|` becomes a literal `|` here while every other
/// backslash escape is left for `parseInlines`. A backslash consumes the byte
/// after it outright, so `\\|` is an escaped backslash followed by a real
/// delimiter.
///
/// A cell that carried no `\|` is a slice of `row`; one that did is rebuilt in
/// `gpa` (the parse arena).
pub fn splitCells(gpa: Allocator, cells: *std.ArrayList([]const u8), row: []const u8) Allocator.Error!void {
    const trimmed = std.mem.trim(u8, row, " ");
    const s = if (trimmed.len > 0 and trimmed[0] == '|') trimmed[1..] else trimmed;
    var start: usize = 0;
    var escaped_pipes: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            if (s[i + 1] == '|') escaped_pipes += 1;
            i += 2;
            continue;
        }
        if (s[i] == '|') {
            try appendCell(gpa, cells, s[start..i], escaped_pipes);
            escaped_pipes = 0;
            start = i + 1;
        }
        i += 1;
    }
    // A row's single trailing boundary pipe leaves `start` at the end with
    // cells already collected; a row that genuinely ends in an empty cell
    // (`| a | |`) reached the end through its own delimiter and keeps it.
    if (start < s.len or cells.items.len == 0)
        try appendCell(gpa, cells, s[start..], escaped_pipes);
}

/// Trim one cell and append it, unescaping its `escaped_pipes` `\|` sequences.
/// Allocates only when there is at least one — trimming removes spaces, and a
/// `\|` pair holds none, so the count still applies after the trim.
fn appendCell(gpa: Allocator, cells: *std.ArrayList([]const u8), raw: []const u8, escaped_pipes: usize) Allocator.Error!void {
    const cell = std.mem.trim(u8, raw, " ");
    if (escaped_pipes == 0) return cells.append(gpa, cell);

    const out = try gpa.alloc(u8, cell.len - escaped_pipes);
    var w: usize = 0;
    var i: usize = 0;
    while (i < cell.len) {
        if (cell[i] == '\\' and i + 1 < cell.len) {
            if (cell[i + 1] == '|') {
                out[w] = '|';
                w += 1;
            } else {
                out[w] = cell[i];
                out[w + 1] = cell[i + 1];
                w += 2;
            }
            i += 2;
            continue;
        }
        out[w] = cell[i];
        w += 1;
        i += 1;
    }
    try cells.append(gpa, out[0..w]);
}

/// Read per-column alignment from the separator row (`:--`, `:-:`, `--:`).
/// The row already passed `isTableStart`'s separator check, and separators
/// can hold no escaped pipes — the simple boundary strip + split is the
/// whole job (body rows need `splitCells`' escape handling; this row can't).
pub fn parseAligns(arena: Allocator, aligns: *std.ArrayList(Align), sep: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, stripBoundaryPipes(std.mem.trim(u8, sep, " ")), '|');
    while (it.next()) |raw| {
        const cell = std.mem.trim(u8, raw, " ");
        const left = cell.len > 0 and cell[0] == ':';
        const right = cell.len > 0 and cell[cell.len - 1] == ':';
        try aligns.append(arena, if (left and right) .center else if (right) .right else if (left) .left else .none);
    }
}

// ---- inline parsing ----------------------------------------------------------

const Link = struct { text: []const u8, url: []const u8, consumed: usize };

/// Parse `[text](url)` starting at the leading `[`.
fn parseLink(s: []const u8) ?Link {
    const close_bracket = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    if (close_bracket + 1 >= s.len or s[close_bracket + 1] != '(') return null;
    const close_paren = std.mem.indexOfScalarPos(u8, s, close_bracket + 2, ')') orelse return null;
    return .{
        .text = s[1..close_bracket],
        .url = s[close_bracket + 2 .. close_paren],
        .consumed = close_paren + 1,
    };
}

const PostfixSpan = struct { text: []const u8, args: []const u8, consumed: usize };

/// The shared mechanics of a `[text].word(args)` postfix span (`.color`,
/// `.cite`): the same first-`]` scan as `parseLink` — which is the
/// restriction story: a link's `[label](url)` wins the `[` first, so a
/// postfix span never attaches to a link, and spans don't nest (the earliest
/// `].word(` closes the span; the rest stays literal). The caller validates
/// `args`; any failure there deactivates the whole span back to prose.
fn parsePostfixSpan(s: []const u8, comptime word: []const u8) ?PostfixSpan {
    const marker = "." ++ word ++ "(";
    const close_bracket = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    if (!std.mem.startsWith(u8, s[close_bracket + 1 ..], marker)) return null;
    const args_start = close_bracket + 1 + marker.len;
    const close_paren = std.mem.indexOfScalarPos(u8, s, args_start, ')') orelse return null;
    return .{
        .text = s[1..close_bracket],
        .args = s[args_start..close_paren],
        .consumed = close_paren + 1,
    };
}

const ColorSpan = struct { text: []const u8, color: TextColor, consumed: usize };

/// Parse `[text].color(role)` starting at the leading `[`
/// (`docs/reference/design/006-color.md`). Unknown roles fail the parse and
/// stay literal prose; empty span text is rejected, matching `.cite`.
fn parseColorSpan(s: []const u8) ?ColorSpan {
    const span = parsePostfixSpan(s, "color") orelse return null;
    if (span.text.len == 0) return null;
    const role = TextColor.parse(span.args) orelse return null;
    return .{ .text = span.text, .color = role, .consumed = span.consumed };
}

const CiteSpanParse = struct { text: []const u8, refs: []CiteRef, consumed: usize };

/// Parse `[text].cite(refs)` starting at the leading `[` — the citation mark
/// (`docs/reference/design/016-citations.md`). `refs` is one or more
/// comma-separated refs, spaces allowed around commas; any malformed ref
/// fails the whole parse so the text stays literal prose. Empty span text
/// (`[].cite(…)`) is rejected — reserved for a possible future
/// point-citation form.
fn parseCiteSpan(arena: Allocator, s: []const u8) Allocator.Error!?CiteSpanParse {
    const span = parsePostfixSpan(s, "cite") orelse return null;
    if (span.text.len == 0) return null;
    var refs: std.ArrayList(CiteRef) = .empty;
    var it = std.mem.splitScalar(u8, span.args, ',');
    while (it.next()) |part| {
        const ref = parseCiteRef(std.mem.trim(u8, part, " ")) orelse return null;
        try refs.append(arena, ref);
    }
    return .{
        .text = span.text,
        .refs = try refs.toOwnedSlice(arena),
        .consumed = span.consumed,
    };
}

/// One `.cite` ref token: all digits is a positional entry number (1-based,
/// resolved on the spot); a key is letters/digits/`-`/`_` with at least one
/// letter. The two shapes are disjoint by grammar — the `skinny`/`wide`
/// trick — so a key can never be mistaken for a position. Anything else
/// fails, deactivating the whole mark.
pub fn parseCiteRef(tok: []const u8) ?CiteRef {
    if (tok.len == 0) return null;
    var has_letter = false;
    var all_digits = true;
    for (tok) |c| {
        if (std.ascii.isAlphabetic(c)) {
            has_letter = true;
            all_digits = false;
        } else if (c == '-' or c == '_') {
            all_digits = false;
        } else if (!std.ascii.isDigit(c)) {
            return null;
        }
    }
    if (all_digits) {
        // `0` is grammar-invalid (entry numbers are 1-based) and fails the
        // mark; a number too big for u32 is grammatically fine but can match
        // nothing — keep that ref unresolved (num 0) so it degrades like an
        // out-of-range number instead of deactivating the whole mark.
        const n = std.fmt.parseInt(u32, tok, 10) catch return .{ .raw = tok };
        if (n == 0) return null;
        return .{ .raw = tok, .num = n };
    }
    if (!has_letter) return null; // `-`/`_` runs alone are not keys
    return .{ .raw = tok };
}

/// GFM punctuation a backslash escapes, plus `$` (math) and `|` (tables).
fn isEscapablePunct(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '~', '<', '>', '$' => true,
        else => false,
    };
}

fn startsWithUrlScheme(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// True if `url` has anything beyond the bare scheme (`https://` alone is prose).
pub fn hasUrlBody(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "https://")) return url.len > "https://".len;
    if (std.mem.startsWith(u8, url, "http://")) return url.len > "http://".len;
    return false;
}

/// Punctuation excluded from the tail of a bare URL: in `see https://z.dev.`
/// the final period is prose, not part of the link.
fn isTrailingPunct(c: u8) bool {
    return switch (c) {
        '.', ',', ';', ':', '!', '?', ')' => true,
        else => false,
    };
}

/// Parse `<http…>` starting at the `<`: the URL between the brackets, or null
/// if this isn't an autolink (wrong scheme, no `>`, whitespace inside).
fn parseAngleAutolink(s: []const u8) ?[]const u8 {
    if (s.len < 2 or !startsWithUrlScheme(s[1..])) return null;
    const end = std.mem.indexOfScalar(u8, s, '>') orelse return null;
    const url = s[1..end];
    if (std.mem.indexOfAny(u8, url, " \t") != null) return null;
    return url;
}

// ---- delimiter flanking (docs/reference/design/014-flanking.md) ------------------------
// Emphasis delimiters are context-sensitive: `a * b * c` is asterisks in prose,
// not emphasis around a space. CommonMark decides this with left/right-flanking
// delimiter runs, and these three helpers are that definition, applied by every
// emphasis arm below. `text` is the *joined* text of a flowing element, so its
// start and end count as whitespace (a span can't open on nothing).

/// ASCII punctuation, per CommonMark's definition (the flanking clauses treat
/// punctuation as a weaker boundary than whitespace).
fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

fn isSpaceChar(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// The character before a run, or null at the start of the text (= whitespace).
fn charBefore(text: []const u8, start: usize) ?u8 {
    return if (start == 0) null else text[start - 1];
}

/// The character after a run, or null at the end of the text (= whitespace).
fn charAfter(text: []const u8, start: usize, len: usize) ?u8 {
    const at = start + len;
    return if (at >= text.len) null else text[at];
}

/// May the delimiter run at `start` (of `len` chars) *open* a span?
/// CommonMark: not followed by whitespace, and either not followed by
/// punctuation, or followed by punctuation and preceded by whitespace or
/// punctuation.
fn isLeftFlanking(text: []const u8, start: usize, len: usize) bool {
    const after = charAfter(text, start, len) orelse return false;
    if (isSpaceChar(after)) return false;
    if (!isAsciiPunct(after)) return true;
    const before = charBefore(text, start) orelse return true;
    return isSpaceChar(before) or isAsciiPunct(before);
}

/// May the delimiter run at `start` (of `len` chars) *close* a span?
/// The mirror of `isLeftFlanking`.
fn isRightFlanking(text: []const u8, start: usize, len: usize) bool {
    const before = charBefore(text, start) orelse return false;
    if (isSpaceChar(before)) return false;
    if (!isAsciiPunct(before)) return true;
    const after = charAfter(text, start, len) orelse return true;
    return isSpaceChar(after) or isAsciiPunct(after);
}

/// The next occurrence of `marker` at or after `from` that can close a span —
/// non-qualifying candidates are skipped, not fatal, so `*a * b*` is one
/// emphasis containing a lone asterisk.
fn findClosingRun(text: []const u8, from: usize, marker: []const u8) ?usize {
    var at = from;
    while (std.mem.indexOfPos(u8, text, at, marker)) |found| {
        if (isRightFlanking(text, found, marker.len)) return found;
        at = found + 1;
    }
    return null;
}

/// The length of the run of `ch` starting at `at`.
fn runLen(text: []const u8, at: usize, ch: u8) usize {
    var n: usize = 0;
    while (at + n < text.len and text[at + n] == ch) n += 1;
    return n;
}

/// The start of the next run of *exactly* `len` backticks at or after `from`
/// (GFM code-span closer matching — longer/shorter runs are skipped whole).
fn findBacktickClose(text: []const u8, from: usize, len: usize) ?usize {
    var at = from;
    while (at < text.len) {
        if (text[at] == '`') {
            const n = runLen(text, at, '`');
            if (n == len) return at;
            at += n;
        } else at += 1;
    }
    return null;
}

/// The closing `$` of an inline-math span opened at `open`, or null if this `$`
/// doesn't open one (docs/reference/design/014-flanking.md): the opener must be followed
/// by a non-space character, the closer preceded by one and not followed by a
/// digit, and the body must be non-empty. Non-qualifying candidates are skipped.
fn findMathClose(text: []const u8, open: usize) ?usize {
    const first = charAfter(text, open, 1) orelse return null;
    if (isSpaceChar(first)) return null;
    var at = open + 1;
    while (std.mem.indexOfScalarPos(u8, text, at, '$')) |found| {
        if (found == open + 1) return null; // empty body: `$$` is not inline math
        const before = text[found - 1];
        const after = charAfter(text, found, 1);
        const digit_follows = if (after) |a| std.ascii.isDigit(a) else false;
        if (!isSpaceChar(before) and !digit_follows) return found;
        at = found + 1;
    }
    return null;
}

/// Parse one line's inline markdown into a run of `Inline` nodes. Literal
/// characters (and unwrapped backslash escapes) accumulate into `.text` runs;
/// structured forms flush the run and append their own node. Recurses for
/// nestable content (link text, emphasis bodies).
pub fn parseInlines(arena: Allocator, text: []const u8) Allocator.Error![]Inline {
    var out: std.ArrayList(Inline) = .empty;
    var pending: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // Backslash escape: the punctuation after `\` becomes literal text,
        // defeating any inline meaning it would otherwise have. Checked first
        // so `` \` `` and `\$` also work.
        if (c == '\\' and i + 1 < text.len and isEscapablePunct(text[i + 1])) {
            try pending.append(arena, text[i + 1]);
            i += 2;
            continue;
        }

        // `inline code` — highest precedence, no nested parsing. GFM run
        // matching: an opener run of N backticks closes at the next run of
        // exactly N, so ``a`b`` embeds a backtick; a run with no matching
        // closer stays literal. One space strips from each end when both
        // are present and the body isn't all spaces (the `` ` `` idiom).
        if (c == '`') {
            const open_len = runLen(text, i, '`');
            if (findBacktickClose(text, i + open_len, open_len)) |close| {
                try flushText(arena, &out, &pending);
                var body = text[i + open_len .. close];
                if (body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ' and
                    std.mem.trim(u8, body, " ").len > 0)
                {
                    body = body[1 .. body.len - 1];
                }
                try out.append(arena, .{ .code = body });
                i = close + open_len;
                continue;
            }
        }

        // $inline math$ — raw TeX; no markdown applies inside. The delimiter
        // rules (014-flanking) keep prose dollars — `costs $5 and $10`,
        // `$HOME and $PATH` — out of the math parser.
        if (c == '$') {
            if (findMathClose(text, i)) |end| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .math = text[i + 1 .. end] });
                i = end + 1;
                continue;
            }
        }

        // ![alt](src) — image. The alt text is plain (not recursed into).
        if (c == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseLink(text[i + 1 ..])) |link| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .image = .{ .src = link.url, .alt = link.text } });
                i += 1 + link.consumed;
                continue;
            }
        }

        // [text](url)
        if (c == '[') {
            if (parseLink(text[i..])) |link| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .link = .{
                    .url = link.url,
                    .children = try parseInlines(arena, link.text),
                } });
                i += link.consumed;
                continue;
            }
            // [text].color(role) — checked after the link form so a link
            // always wins its `[`.
            if (parseColorSpan(text[i..])) |span| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .color_span = .{
                    .color = span.color,
                    .children = try parseInlines(arena, span.text),
                } });
                i += span.consumed;
                continue;
            }
            // [text].cite(refs) — the citation mark (016-citations), likewise
            // behind the link form.
            if (try parseCiteSpan(arena, text[i..])) |span| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .cite_span = .{
                    .refs = span.refs,
                    .children = try parseInlines(arena, span.text),
                } });
                i += span.consumed;
                continue;
            }
        }

        // <https://…> — explicit autolink.
        if (c == '<') {
            if (parseAngleAutolink(text[i..])) |url| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .autolink = url });
                i += url.len + 2;
                continue;
            }
        }

        // Bare http(s):// URL at a word boundary. Conservative: only these two
        // schemes, and trailing punctuation stays outside the link.
        if (c == 'h' and (i == 0 or text[i - 1] == ' ' or text[i - 1] == '(') and
            startsWithUrlScheme(text[i..]))
        {
            var end = i;
            while (end < text.len and text[end] != ' ' and text[end] != '<') end += 1;
            while (end > i and isTrailingPunct(text[end - 1])) end -= 1;
            const url = text[i..end];
            if (hasUrlBody(url)) {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .autolink = url });
                i = end;
                continue;
            }
        }

        // Emphasis and strikethrough. Every arm gates on flanking
        // (014-flanking): the opening run must be left-flanking and the
        // closing run right-flanking, so `a * b * c` and `5 * 4 * 3` stay
        // literal asterisks the way they do in every other renderer.

        // ***bold italic*** — checked before **bold** so the third star isn't
        // left over as a literal character.
        if (c == '*' and i + 2 < text.len and text[i + 1] == '*' and text[i + 2] == '*' and
            isLeftFlanking(text, i, 3))
        {
            if (findClosingRun(text, i + 3, "***")) |end| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .strong_em = try parseInlines(arena, text[i + 3 .. end]) });
                i = end + 3;
                continue;
            }
        }

        // **bold**
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*' and isLeftFlanking(text, i, 2)) {
            if (findClosingRun(text, i + 2, "**")) |end| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .strong = try parseInlines(arena, text[i + 2 .. end]) });
                i = end + 2;
                continue;
            }
        }

        // *italic*
        if (c == '*' and isLeftFlanking(text, i, 1)) {
            if (findClosingRun(text, i + 1, "*")) |end| {
                if (end > i + 1) {
                    try flushText(arena, &out, &pending);
                    try out.append(arena, .{ .em = try parseInlines(arena, text[i + 1 .. end]) });
                    i = end + 1;
                    continue;
                }
            }
        }

        // ~~strikethrough~~
        if (c == '~' and i + 1 < text.len and text[i + 1] == '~' and isLeftFlanking(text, i, 2)) {
            if (findClosingRun(text, i + 2, "~~")) |end| {
                if (end > i + 2) {
                    try flushText(arena, &out, &pending);
                    try out.append(arena, .{ .strike = try parseInlines(arena, text[i + 2 .. end]) });
                    i = end + 2;
                    continue;
                }
            }
        }

        try pending.append(arena, c);
        i += 1;
    }
    try flushText(arena, &out, &pending);
    return out.toOwnedSlice(arena);
}

/// Move any accumulated literal characters into a `.text` node.
fn flushText(arena: Allocator, out: *std.ArrayList(Inline), pending: *std.ArrayList(u8)) Allocator.Error!void {
    if (pending.items.len == 0) return;
    try out.append(arena, .{ .text = try pending.toOwnedSlice(arena) });
}

