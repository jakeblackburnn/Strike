//! A small markdown -> HTML renderer.
//!
//! Supports a practical GFM subset of markdown:
//!   - ATX headings (`#` .. `######`) with auto anchor ids (see `slugify`)
//!   - paragraphs (soft-wrapped lines are joined with a space)
//!   - `**bold**`, `*italic*`, `***bold italic***`, `~~strikethrough~~`,
//!     `` `inline code` ``, `[text](url)` links, `![alt](src)` images,
//!     `<https://…>` and bare-URL autolinks, and backslash escapes (`\*`)
//!   - unordered (`-`/`*`/`+`) and ordered (`1.`) lists, nested by
//!     indentation, with `- [ ]`/`- [x]` task boxes
//!   - GFM pipe tables (header + `|---|` separator, `:-:` alignment)
//!   - fenced code blocks (```` ``` ````), the info string's first token
//!     emitted as `class="language-…"`
//!   - blockquotes (`>`)
//!   - horizontal rules (`---` / `***` / `___`)
//!   - LaTeX math: inline `$…$` -> `\(…\)`, display `$$…$$` -> `\[…\]`
//!     (delimiters only — typeset client-side; see `shell.zig`'s MathJax loader)
//!
//! `render` is a pure function (no I/O) and the file's only entry point. Page
//! chrome (CSS/JS/`Shell`) lives in `shell.zig`; site-structure-aware rendering
//! (nav tree, project picker) lives in `site.zig`. This file depends on nothing
//! but `html.zig` — it's the markdown/`.sx` engine and nothing else.

const std = @import("std");
const html = @import("html.zig");
const escapeChar = html.escapeChar;
const escapeInto = html.escapeInto;
const escapeAttrInto = html.escapeAttrInto;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Which dialect `render` should parse: the plain `.md` subset described above,
/// or the (currently identical) `.sx` superset. A future `.sx`-only inline form
/// is added as a plain `if (flavor == .sx)` arm in `renderInline`'s loop, the
/// same shape every existing case already uses. A future `.sx`-only *block*
/// form additionally needs `isBlockStart` (currently flavor-less, since nothing
/// gates on it yet) to gain the same parameter and a matching arm — otherwise a
/// paragraph immediately before the new block swallows it as a soft-wrap
/// continuation. No registry, no per-flavor file.
pub const Flavor = enum { md, sx };

/// Render `md` to an HTML fragment (no surrounding `<html>`/`<body>`).
/// Caller owns the returned slice and must free it with `allocator`.
pub fn render(allocator: Allocator, md: []const u8, flavor: Flavor) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // Collect the document into lines so block parsers can look ahead.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, md, '\n');
        while (it.next()) |raw| {
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try lines.append(allocator, line);
        }
    }

    // Heading anchor slugs used so far in this document (for deduping).
    var used_slugs: std.ArrayList([]const u8) = .empty;
    defer {
        for (used_slugs.items) |s| allocator.free(s);
        used_slugs.deinit(allocator);
    }

    var idx: usize = 0;
    while (idx < lines.items.len) {
        const line = lines.items[idx];
        const t = std.mem.trimStart(u8, line, " ");

        if (isBlank(line)) {
            idx += 1;
            continue;
        }

        // Fenced code block: contents are escaped verbatim, no inline parsing.
        if (std.mem.startsWith(u8, t, "```")) {
            // Info string: the first token names the language (```python ->
            // class="language-python"); anything after it is ignored.
            const info = std.mem.trim(u8, t[3..], " ");
            const lang = info[0 .. std.mem.indexOfScalar(u8, info, ' ') orelse info.len];
            idx += 1;
            if (lang.len > 0) {
                try w.writeAll("<pre><code class=\"language-");
                try escapeAttrInto(w, lang);
                try w.writeAll("\">");
            } else {
                try w.writeAll("<pre><code>");
            }
            while (idx < lines.items.len and
                !std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[idx], " "), "```"))
            {
                try escapeInto(w, lines.items[idx]);
                try w.writeByte('\n');
                idx += 1;
            }
            if (idx < lines.items.len) idx += 1; // consume the closing fence
            try w.writeAll("</code></pre>\n");
            continue;
        }

        // Display math: `$$…$$`. Pass the TeX through (HTML-escaped) wrapped in
        // `\[ … \]` so client-side MathJax typesets it.
        if (std.mem.startsWith(u8, t, "$$")) {
            const rest = std.mem.trimEnd(u8, t, " ");
            // Single-line `$$ … $$` (every instance in the sample is like this).
            if (rest.len >= 4 and std.mem.endsWith(u8, rest, "$$")) {
                try w.writeAll("\\[");
                try escapeInto(w, rest[2 .. rest.len - 2]);
                try w.writeAll("\\]\n");
                idx += 1;
                continue;
            }
            // Multi-line fallback: gather until a line ending in `$$`.
            try w.writeAll("\\[");
            try escapeInto(w, std.mem.trimStart(u8, rest, "$"));
            idx += 1;
            while (idx < lines.items.len) {
                const ml = std.mem.trimEnd(u8, lines.items[idx], " ");
                try w.writeByte('\n');
                if (std.mem.endsWith(u8, ml, "$$")) {
                    try escapeInto(w, ml[0 .. ml.len - 2]);
                    idx += 1;
                    break;
                }
                try escapeInto(w, ml);
                idx += 1;
            }
            try w.writeAll("\\]\n");
            continue;
        }

        // ATX heading. The anchor id comes from the raw heading text (markdown
        // punctuation collapses into `-` naturally), deduped per document.
        if (headingLevel(t)) |level| {
            const text = std.mem.trim(u8, t[level..], " ");
            const slug = try uniqueSlug(allocator, &used_slugs, text);
            try w.print("<h{d} id=\"", .{level});
            try escapeAttrInto(w, slug);
            try w.writeAll("\">");
            try renderInline(w, text, flavor);
            try w.print("</h{d}>\n", .{level});
            idx += 1;
            continue;
        }

        // Horizontal rule (checked before lists so `---` is not a list item).
        if (isHorizontalRule(t)) {
            try w.writeAll("<hr/>\n");
            idx += 1;
            continue;
        }

        // Blockquote: a run of consecutive `>` lines.
        if (std.mem.startsWith(u8, t, ">")) {
            try w.writeAll("<blockquote>\n");
            while (idx < lines.items.len) {
                const qt = std.mem.trimStart(u8, lines.items[idx], " ");
                if (!std.mem.startsWith(u8, qt, ">")) break;
                var content = qt[1..];
                if (content.len > 0 and content[0] == ' ') content = content[1..];
                try w.writeAll("<p>");
                try renderInline(w, std.mem.trimEnd(u8, content, " "), flavor);
                try w.writeAll("</p>\n");
                idx += 1;
            }
            try w.writeAll("</blockquote>\n");
            continue;
        }

        // List (unordered or ordered, possibly nested by indentation).
        if (parseMarker(t) != null) {
            try renderList(w, lines.items, &idx, flavor);
            continue;
        }

        // GFM pipe table: a header row followed by a `|---|` separator row.
        if (isTableStart(lines.items, idx)) {
            var header: std.ArrayList([]const u8) = .empty;
            defer header.deinit(allocator);
            try splitCells(allocator, &header, std.mem.trimStart(u8, lines.items[idx], " "));
            var aligns: std.ArrayList(Align) = .empty;
            defer aligns.deinit(allocator);
            try parseAligns(allocator, &aligns, std.mem.trimStart(u8, lines.items[idx + 1], " "));
            idx += 2;

            try w.writeAll("<table>\n<thead>\n<tr>");
            for (header.items, 0..) |cell, ci| {
                try writeCell(w, "th", alignAt(aligns.items, ci), cell, flavor);
            }
            try w.writeAll("</tr>\n</thead>\n<tbody>\n");
            var row: std.ArrayList([]const u8) = .empty;
            defer row.deinit(allocator);
            while (idx < lines.items.len) {
                const rt = std.mem.trimStart(u8, lines.items[idx], " ");
                if (isBlank(lines.items[idx]) or isBlockStart(rt) or
                    std.mem.indexOfScalar(u8, rt, '|') == null) break;
                row.clearRetainingCapacity();
                try splitCells(allocator, &row, rt);
                try w.writeAll("<tr>");
                // GFM: pad/truncate every body row to the header's column count.
                for (0..header.items.len) |ci| {
                    const cell = if (ci < row.items.len) row.items[ci] else "";
                    try writeCell(w, "td", alignAt(aligns.items, ci), cell, flavor);
                }
                try w.writeAll("</tr>\n");
                idx += 1;
            }
            try w.writeAll("</tbody>\n</table>\n");
            continue;
        }

        // Paragraph: gather consecutive lines until a blank line or a new block.
        try w.writeAll("<p>");
        try renderInline(w, std.mem.trimEnd(u8, t, " "), flavor);
        idx += 1;
        while (idx < lines.items.len and !isBlank(lines.items[idx])) {
            const nt = std.mem.trim(u8, lines.items[idx], " ");
            // `isTableStart` is the table's paragraph-interrupt companion to
            // `isBlockStart` (a table is a two-line pattern, so it can't live
            // in the single-line `isBlockStart`).
            if (isBlockStart(nt) or isTableStart(lines.items, idx)) break;
            try w.writeByte(' ');
            try renderInline(w, nt, flavor);
            idx += 1;
        }
        try w.writeAll("</p>\n");
    }

    return out.toOwnedSlice();
}

/// Turn heading text into an anchor slug: lowercased, `a-z0-9` kept, every
/// other run of characters collapsed to a single `-`, no leading/trailing `-`.
/// Falls back to `"section"` when nothing survives. Exported for future
/// TOC/copy-link features. Caller owns the result.
pub fn slugify(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_dash = false;
    for (text) |c| {
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            if (pending_dash and out.items.len > 0) try out.append(gpa, '-');
            pending_dash = false;
            try out.append(gpa, lower);
        } else {
            pending_dash = true;
        }
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "section");
    return out.toOwnedSlice(gpa);
}

/// `slugify` plus per-document deduplication: a repeated heading gets a `-2`,
/// `-3`, … suffix. The winning slug is appended to `used`, which owns it.
fn uniqueSlug(gpa: Allocator, used: *std.ArrayList([]const u8), text: []const u8) ![]const u8 {
    const base = try slugify(gpa, text);
    if (!slugInUse(used.items, base)) {
        try used.append(gpa, base);
        return base;
    }
    defer gpa.free(base);
    var n: usize = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(gpa, "{s}-{d}", .{ base, n });
        if (!slugInUse(used.items, candidate)) {
            try used.append(gpa, candidate);
            return candidate;
        }
        gpa.free(candidate);
    }
}

fn slugInUse(used: []const []const u8, slug: []const u8) bool {
    for (used) |s| if (std.mem.eql(u8, s, slug)) return true;
    return false;
}

// ---- block helpers ----------------------------------------------------------

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// Returns true if a (left-trimmed) line begins any block other than a
/// paragraph. Pipe tables are the one block NOT covered here — they're a
/// two-line pattern, so the paragraph loop (and anything else that needs to
/// stop before a table) additionally checks `isTableStart(lines, idx)`.
fn isBlockStart(t: []const u8) bool {
    return headingLevel(t) != null or
        isHorizontalRule(t) or
        std.mem.startsWith(u8, t, ">") or
        std.mem.startsWith(u8, t, "```") or
        std.mem.startsWith(u8, t, "$$") or
        isUnorderedItem(t) or
        orderedMarkerLen(t) != null;
}

/// `# ` .. `###### ` -> heading level 1..6, otherwise null.
fn headingLevel(t: []const u8) ?usize {
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n >= 1 and n <= 6 and n < t.len and t[n] == ' ') return n;
    return null;
}

fn isHorizontalRule(t: []const u8) bool {
    const s = std.mem.trim(u8, t, " ");
    if (s.len < 3) return false;
    const c = s[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (s) |ch| if (ch != c) return false;
    return true;
}

fn isUnorderedItem(t: []const u8) bool {
    return t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ';
}

/// Leading-whitespace width in columns (a tab counts as 4).
fn indentWidth(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4;
        } else break;
    }
    return n;
}

const Marker = struct {
    ordered: bool,
    /// Offset of the item text within the trimmed line (past marker + task box).
    content_start: usize,
    /// null = plain item; true/false = checked/unchecked task box.
    task: ?bool,
};

/// Parse a list-item marker (`- `, `* `, `+ `, `12. `) at the start of a
/// left-trimmed line, plus an optional `[ ]`/`[x]` task box after it.
fn parseMarker(t: []const u8) ?Marker {
    var m: Marker = undefined;
    if (isUnorderedItem(t)) {
        m = .{ .ordered = false, .content_start = 2, .task = null };
    } else if (orderedMarkerLen(t)) |mlen| {
        m = .{ .ordered = true, .content_start = mlen, .task = null };
    } else return null;
    const rest = t[m.content_start..];
    if (std.mem.startsWith(u8, rest, "[ ]") and (rest.len == 3 or rest[3] == ' ')) {
        m.task = false;
        m.content_start += @min(rest.len, 4);
    } else if ((std.mem.startsWith(u8, rest, "[x]") or std.mem.startsWith(u8, rest, "[X]")) and
        (rest.len == 3 or rest[3] == ' '))
    {
        m.task = true;
        m.content_start += @min(rest.len, 4);
    }
    return m;
}

/// Render one (possibly nested) list starting at `idx.*`, advancing it past
/// the consumed lines. Nesting is by indentation: an item indented >= 2
/// columns past its parent opens a child list inside the parent's `<li>`; a
/// dedent returns to the outer level; a marker of the other orderedness at
/// the same level ends this list (the block loop starts the sibling). An
/// indented non-marker line soft-wraps into the open item; an unindented one
/// — or a blank line — ends the list (loose lists are out of scope, as
/// before).
fn renderList(w: *Writer, lines: []const []const u8, idx: *usize, flavor: Flavor) Writer.Error!void {
    const base = indentWidth(lines[idx.*]);
    const first = parseMarker(std.mem.trimStart(u8, lines[idx.*], " \t")) orelse unreachable;
    const ordered = first.ordered;
    try w.writeAll(if (ordered) "<ol>\n" else "<ul>\n");
    var li_open = false;
    while (idx.* < lines.len) {
        const line = lines[idx.*];
        if (isBlank(line)) break;
        const ind = indentWidth(line);
        const t = std.mem.trimStart(u8, line, " \t");
        if (parseMarker(t)) |m| {
            if (ind >= base + 2) {
                if (!li_open) break;
                try w.writeByte('\n');
                try renderList(w, lines, idx, flavor);
                continue;
            }
            if (ind < base or m.ordered != ordered) break;
            if (li_open) try w.writeAll("</li>\n");
            try w.writeAll("<li>");
            li_open = true;
            if (m.task) |checked| {
                try w.writeAll(if (checked)
                    "<input type=\"checkbox\" disabled checked> "
                else
                    "<input type=\"checkbox\" disabled> ");
            }
            try renderInline(w, std.mem.trimEnd(u8, t[m.content_start..], " "), flavor);
            idx.* += 1;
            continue;
        }
        // Non-marker line: an indented one continues the open item; anything
        // else ends the list (the block loop decides what it is).
        if (li_open and ind > base and !isBlockStart(t)) {
            try w.writeByte(' ');
            try renderInline(w, std.mem.trimEnd(u8, t, " "), flavor);
            idx.* += 1;
            continue;
        }
        break;
    }
    if (li_open) try w.writeAll("</li>\n");
    try w.writeAll(if (ordered) "</ol>\n" else "</ul>\n");
}

/// Length of an ordered-list marker like `12. `, or null if the line isn't one.
fn orderedMarkerLen(t: []const u8) ?usize {
    var n: usize = 0;
    while (n < t.len and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0) return null;
    if (n + 1 < t.len and t[n] == '.' and t[n + 1] == ' ') return n + 2;
    return null;
}

// ---- table helpers ----------------------------------------------------------

const Align = enum { none, left, center, right };

/// Two-line lookahead: a non-block line containing a `|`, followed by a
/// separator row, starts a table.
fn isTableStart(lines: []const []const u8, idx: usize) bool {
    if (idx + 1 >= lines.len or isBlank(lines[idx])) return false;
    const t = std.mem.trimStart(u8, lines[idx], " ");
    if (isBlockStart(t) or std.mem.indexOfScalar(u8, t, '|') == null) return false;
    return isTableSeparator(std.mem.trimStart(u8, lines[idx + 1], " "));
}

/// A GFM table separator row: cells of `-`s with optional `:` alignment
/// colons, split on `|`. Requires at least one pipe (a bare `---` is an HR).
fn isTableSeparator(t: []const u8) bool {
    const s = std.mem.trim(u8, t, " ");
    if (std.mem.indexOfScalar(u8, s, '|') == null) return false;
    var it = std.mem.splitScalar(u8, stripBoundaryPipes(s), '|');
    while (it.next()) |cell_raw| {
        var cell = std.mem.trim(u8, cell_raw, " ");
        if (cell.len == 0) return false;
        if (cell[0] == ':') cell = cell[1..];
        if (cell.len > 0 and cell[cell.len - 1] == ':') cell = cell[0 .. cell.len - 1];
        if (cell.len == 0) return false;
        for (cell) |ch| if (ch != '-') return false;
    }
    return true;
}

/// Strip at most one leading and one trailing boundary pipe (an escaped
/// trailing `\|` is cell content, not a boundary).
fn stripBoundaryPipes(s: []const u8) []const u8 {
    var r = s;
    if (r.len > 0 and r[0] == '|') r = r[1..];
    if (r.len > 0 and r[r.len - 1] == '|' and (r.len < 2 or r[r.len - 2] != '\\'))
        r = r[0 .. r.len - 1];
    return r;
}

/// Split a table row into trimmed cells on unescaped `|`s. `\|` survives
/// inside a cell for `renderInline`'s escape handling to unwrap later.
fn splitCells(gpa: Allocator, cells: *std.ArrayList([]const u8), row: []const u8) !void {
    const s = stripBoundaryPipes(std.mem.trim(u8, row, " "));
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or (s[i] == '|' and (i == 0 or s[i - 1] != '\\'))) {
            try cells.append(gpa, std.mem.trim(u8, s[start..i], " "));
            start = i + 1;
        }
    }
}

/// Read per-column alignment from the separator row (`:--`, `:-:`, `--:`).
fn parseAligns(gpa: Allocator, aligns: *std.ArrayList(Align), sep: []const u8) !void {
    var cells: std.ArrayList([]const u8) = .empty;
    defer cells.deinit(gpa);
    try splitCells(gpa, &cells, sep);
    for (cells.items) |cell| {
        const left = cell.len > 0 and cell[0] == ':';
        const right = cell.len > 0 and cell[cell.len - 1] == ':';
        try aligns.append(gpa, if (left and right) .center else if (right) .right else if (left) .left else .none);
    }
}

fn alignAt(aligns: []const Align, i: usize) Align {
    return if (i < aligns.len) aligns[i] else .none;
}

/// One `<th>`/`<td>` with its alignment style and inline-rendered content.
fn writeCell(w: *Writer, tag: []const u8, al: Align, cell: []const u8, flavor: Flavor) Writer.Error!void {
    try w.writeByte('<');
    try w.writeAll(tag);
    switch (al) {
        .none => {},
        .left => try w.writeAll(" style=\"text-align:left\""),
        .center => try w.writeAll(" style=\"text-align:center\""),
        .right => try w.writeAll(" style=\"text-align:right\""),
    }
    try w.writeByte('>');
    try renderInline(w, cell, flavor);
    try w.writeAll("</");
    try w.writeAll(tag);
    try w.writeByte('>');
}

// ---- inline helpers ---------------------------------------------------------

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
fn hasUrlBody(url: []const u8) bool {
    const scheme_len: usize = if (std.mem.startsWith(u8, url, "https://")) 8 else 7;
    return url.len > scheme_len;
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

/// `<a href="url">url</a>` — the shared tail of both autolink forms.
fn writeUrlAnchor(w: *Writer, url: []const u8) Writer.Error!void {
    try w.writeAll("<a href=\"");
    try escapeAttrInto(w, url);
    try w.writeAll("\">");
    try escapeInto(w, url);
    try w.writeAll("</a>");
}

/// Render inline markdown (escaping, code, links, bold, italic) into `w`.
fn renderInline(w: *Writer, text: []const u8, flavor: Flavor) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // Backslash escape: the punctuation after `\` is emitted literally,
        // defeating any inline meaning it would otherwise have. Checked first
        // so `` \` `` and `\$` also work.
        if (c == '\\' and i + 1 < text.len and isEscapablePunct(text[i + 1])) {
            try escapeChar(w, text[i + 1]);
            i += 2;
            continue;
        }

        // `inline code` — highest precedence, no nested formatting.
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try w.writeAll("<code>");
                try escapeInto(w, text[i + 1 .. end]);
                try w.writeAll("</code>");
                i = end + 1;
                continue;
            }
        }

        // $inline math$ — pass TeX through (escaped) as `\( … \)` for MathJax.
        // No markdown is applied inside; highest precedence after code.
        if (c == '$') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '$')) |end| {
                try w.writeAll("\\(");
                try escapeInto(w, text[i + 1 .. end]);
                try w.writeAll("\\)");
                i = end + 1;
                continue;
            }
        }

        // ![alt](src) — image. The alt text is plain (not recursed into).
        if (c == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseLink(text[i + 1 ..])) |link| {
                try w.writeAll("<img src=\"");
                try escapeAttrInto(w, link.url);
                try w.writeAll("\" alt=\"");
                try escapeAttrInto(w, link.text);
                try w.writeAll("\">");
                i += 1 + link.consumed;
                continue;
            }
        }

        // [text](url)
        if (c == '[') {
            if (parseLink(text[i..])) |link| {
                try w.writeAll("<a href=\"");
                try escapeAttrInto(w, link.url);
                try w.writeAll("\">");
                try renderInline(w, link.text, flavor);
                try w.writeAll("</a>");
                i += link.consumed;
                continue;
            }
        }

        // <https://…> — explicit autolink.
        if (c == '<') {
            if (parseAngleAutolink(text[i..])) |url| {
                try writeUrlAnchor(w, url);
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
                try writeUrlAnchor(w, url);
                i = end;
                continue;
            }
        }

        // ***bold italic*** — checked before **bold** so the third star isn't
        // left over as a literal character.
        if (c == '*' and i + 2 < text.len and text[i + 1] == '*' and text[i + 2] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 3, "***")) |end| {
                try w.writeAll("<strong><em>");
                try renderInline(w, text[i + 3 .. end], flavor);
                try w.writeAll("</em></strong>");
                i = end + 3;
                continue;
            }
        }

        // **bold**
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try w.writeAll("<strong>");
                try renderInline(w, text[i + 2 .. end], flavor);
                try w.writeAll("</strong>");
                i = end + 2;
                continue;
            }
        }

        // *italic*
        if (c == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                if (end > i + 1) {
                    try w.writeAll("<em>");
                    try renderInline(w, text[i + 1 .. end], flavor);
                    try w.writeAll("</em>");
                    i = end + 1;
                    continue;
                }
            }
        }

        // ~~strikethrough~~
        if (c == '~' and i + 1 < text.len and text[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                if (end > i + 2) {
                    try w.writeAll("<del>");
                    try renderInline(w, text[i + 2 .. end], flavor);
                    try w.writeAll("</del>");
                    i = end + 2;
                    continue;
                }
            }
        }

        try escapeChar(w, c);
        i += 1;
    }
}

// ---- tests ------------------------------------------------------------------

fn expectRender(expected: []const u8, md: []const u8) !void {
    const got = try render(std.testing.allocator, md, .md);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "headings" {
    try expectRender("<h1 id=\"title\">Title</h1>\n", "# Title");
    try expectRender("<h3 id=\"sub\">Sub</h3>\n", "### Sub");
    // seven hashes is not a heading -> paragraph
    try expectRender("<p>####### nope</p>\n", "####### nope");
}

test "heading anchor ids" {
    try expectRender("<h2 id=\"my-heading\">My Heading!</h2>\n", "## My Heading!");
    // repeated headings dedupe with -2, -3, …
    try expectRender(
        "<h1 id=\"a\">A</h1>\n<h1 id=\"a-2\">A</h1>\n",
        "# A\n\n# A",
    );
    // slug comes from the raw text; inline markup collapses to dashes
    try expectRender(
        "<h2 id=\"use-code-now\">Use <code>code</code> now</h2>\n",
        "## Use `code` now",
    );
    // all-punctuation heading falls back to "section"
    try expectRender("<h1 id=\"section\">???</h1>\n", "# ???");
}

test "slugify" {
    const gpa = std.testing.allocator;
    const s1 = try slugify(gpa, "Hello, World!");
    defer gpa.free(s1);
    try std.testing.expectEqualStrings("hello-world", s1);
    const s2 = try slugify(gpa, "  --- ");
    defer gpa.free(s2);
    try std.testing.expectEqualStrings("section", s2);
    const s3 = try slugify(gpa, "K-Means (k=3)");
    defer gpa.free(s3);
    try std.testing.expectEqualStrings("k-means-k-3", s3);
}

test "paragraph joins soft-wrapped lines" {
    try expectRender("<p>one two</p>\n", "one\ntwo");
    try expectRender("<p>a</p>\n<p>b</p>\n", "a\n\nb");
}

test "inline bold, italic and code" {
    try expectRender("<p><strong>b</strong> and <em>i</em></p>\n", "**b** and *i*");
    try expectRender("<p>use <code>x &lt; y</code></p>\n", "use `x < y`");
}

test "triple-star renders nested bold+italic, not a leftover asterisk" {
    try expectRender("<p><strong><em>both</em></strong></p>\n", "***both***");
    try expectRender("<p>a <strong><em>b</em></strong> c</p>\n", "a ***b*** c");
}

test "flavor does not yet change rendering (no .sx-only syntax exists)" {
    const md = "# Title\n\n**bold**, *italic*, ***both***, and `code`.";
    const via_md = try render(std.testing.allocator, md, .md);
    defer std.testing.allocator.free(via_md);
    const via_sx = try render(std.testing.allocator, md, .sx);
    defer std.testing.allocator.free(via_sx);
    try std.testing.expectEqualStrings(via_md, via_sx);
}

test "links" {
    try expectRender(
        "<p><a href=\"https://z.dev\">Zig</a></p>\n",
        "[Zig](https://z.dev)",
    );
}

test "unordered and ordered lists" {
    try expectRender("<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", "- a\n- b");
    try expectRender("<ol>\n<li>x</li>\n<li>y</li>\n</ol>\n", "1. x\n2. y");
    // `*` and `+` bullets still work
    try expectRender("<ul>\n<li>a</li>\n</ul>\n", "* a");
    try expectRender("<ul>\n<li>a</li>\n</ul>\n", "+ a");
}

test "nested unordered lists" {
    try expectRender(
        "<ul>\n<li>a\n<ul>\n<li>a1</li>\n</ul>\n</li>\n<li>b</li>\n</ul>\n",
        "- a\n  - a1\n- b",
    );
}

test "ordered list nested in unordered" {
    try expectRender(
        "<ul>\n<li>a\n<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n</li>\n</ul>\n",
        "- a\n  1. one\n  2. two",
    );
}

test "three levels of nesting" {
    try expectRender(
        "<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n",
        "- a\n  - b\n    - c",
    );
}

test "task lists" {
    try expectRender(
        "<ul>\n<li><input type=\"checkbox\" disabled checked> done</li>\n" ++
            "<li><input type=\"checkbox\" disabled> todo</li>\n</ul>\n",
        "- [x] done\n- [ ] todo",
    );
}

test "list item continuation lines join the item" {
    try expectRender("<ul>\n<li>a b</li>\n</ul>\n", "- a\n  b");
}

test "unindented line after a list becomes a paragraph" {
    try expectRender("<ul>\n<li>a</li>\n</ul>\n<p>text</p>\n", "- a\ntext");
}

test "sibling list of the other kind splits" {
    try expectRender(
        "<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>one</li>\n</ol>\n",
        "- a\n1. one",
    );
}

test "fenced code block escapes and skips inline parsing" {
    try expectRender(
        "<pre><code>let x = &amp;y;\n**not bold**\n</code></pre>\n",
        "```\nlet x = &y;\n**not bold**\n```",
    );
}

test "blockquote" {
    try expectRender("<blockquote>\n<p>quoted</p>\n</blockquote>\n", "> quoted");
}

test "horizontal rule vs list item" {
    try expectRender("<hr/>\n", "---");
    try expectRender("<ul>\n<li>x</li>\n</ul>\n", "- x");
}

test "html is escaped in paragraphs" {
    try expectRender("<p>a &amp; b &lt;tag&gt;</p>\n", "a & b <tag>");
}

test "inline math passes through as \\( \\)" {
    try expectRender("<p>see \\(a^2\\)</p>\n", "see $a^2$");
}

test "display math passes through as \\[ \\]" {
    try expectRender("\\[E=mc^2\\]\n", "$$E=mc^2$$");
}

test "math is html-escaped but not markdown-parsed" {
    try expectRender("<p>\\(a &lt; b\\)</p>\n", "$a < b$");
    try expectRender("<p>\\(a*b*c\\)</p>\n", "$a*b*c$");
}

test "backslash escapes make punctuation literal" {
    try expectRender("<p>*not em*</p>\n", "\\*not em\\*");
    try expectRender("<p>`x`</p>\n", "\\`x\\`");
    try expectRender("<p>$5 and $6</p>\n", "\\$5 and \\$6");
    // a backslash before a non-escapable char (or at end of line) is literal
    try expectRender("<p>a\\b \\</p>\n", "a\\b \\");
}

test "images" {
    try expectRender(
        "<p><img src=\"cat.png\" alt=\"a cat\"></p>\n",
        "![a cat](cat.png)",
    );
    // alt and src are attribute-escaped, alt is not inline-parsed
    try expectRender(
        "<p><img src=\"a&quot;.png\" alt=\"**x**\"></p>\n",
        "![**x**](a\".png)",
    );
    // a bare `!` stays literal
    try expectRender("<p>hey!</p>\n", "hey!");
}

test "angle autolinks" {
    try expectRender(
        "<p>see <a href=\"https://z.dev\">https://z.dev</a></p>\n",
        "see <https://z.dev>",
    );
    // non-URL angle content is still escaped, not linked
    try expectRender("<p>&lt;tag&gt;</p>\n", "<tag>");
}

test "bare URLs" {
    try expectRender(
        "<p>go to <a href=\"https://z.dev/x\">https://z.dev/x</a>.</p>\n",
        "go to https://z.dev/x.",
    );
    try expectRender(
        "<p>(<a href=\"http://a.io\">http://a.io</a>)</p>\n",
        "(http://a.io)",
    );
    // inside a code span, untouched
    try expectRender("<p><code>https://z.dev</code></p>\n", "`https://z.dev`");
    // a bare scheme with no body is prose
    try expectRender("<p>https:// is a scheme</p>\n", "https:// is a scheme");
}

test "strikethrough" {
    try expectRender("<p><del>gone</del></p>\n", "~~gone~~");
    try expectRender("<p><del>a <strong>b</strong></del></p>\n", "~~a **b**~~");
    try expectRender("<p>~~ not closed</p>\n", "~~ not closed");
}

test "pipe tables" {
    try expectRender(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        "| a | b |\n| --- | --- |\n| 1 | 2 |",
    );
    // boundary pipes are optional
    try expectRender(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        "a | b\n--- | ---\n1 | 2",
    );
}

test "table alignment" {
    try expectRender(
        "<table>\n<thead>\n<tr><th style=\"text-align:left\">l</th>" ++
            "<th style=\"text-align:center\">c</th>" ++
            "<th style=\"text-align:right\">r</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td style=\"text-align:left\">1</td>" ++
            "<td style=\"text-align:center\">2</td>" ++
            "<td style=\"text-align:right\">3</td></tr>\n</tbody>\n</table>\n",
        "| l | c | r |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |",
    );
}

test "table rows pad and truncate to the header width" {
    try expectRender(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>1</td><td></td></tr>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |",
    );
}

test "inline markup inside table cells" {
    try expectRender(
        "<table>\n<thead>\n<tr><th><strong>a</strong></th><th><code>c</code></th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>\\(x\\)</td><td><em>i</em></td></tr>\n</tbody>\n</table>\n",
        "| **a** | `c` |\n|---|---|\n| $x$ | *i* |",
    );
}

test "escaped pipe stays inside its cell" {
    try expectRender(
        "<table>\n<thead>\n<tr><th>a|b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>x</td></tr>\n</tbody>\n</table>\n",
        "| a\\|b |\n|---|\n| x |",
    );
}

test "table interrupts a paragraph" {
    try expectRender(
        "<p>intro</p>\n<table>\n<thead>\n<tr><th>a</th></tr>\n</thead>\n<tbody>\n</tbody>\n</table>\n",
        "intro\n| a |\n|---|",
    );
}

test "pipe row without a separator stays a paragraph" {
    try expectRender("<p>| a | b |</p>\n", "| a | b |");
}

test "fenced code language class" {
    try expectRender(
        "<pre><code class=\"language-python\">x = 1\n</code></pre>\n",
        "```python\nx = 1\n```",
    );
    // no info string -> no class attribute (existing behavior)
    try expectRender("<pre><code>x\n</code></pre>\n", "```\nx\n```");
}
