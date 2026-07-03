//! The strikedown document model and parser.
//!
//! Strikedown (`.sx`) is a typography-first superset of markdown; plain `.md`
//! is its subset and parses through the exact same pipeline — there is no
//! dialect flag anywhere (see CLAUDE.md "Strikedown direction"). This file
//! turns source text into a `Doc` tree; emitters walk the tree to produce
//! output (`render_html.zig` today, a PDF backend eventually). `parse` is pure
//! — **no I/O, no HTML** — and everything it returns lives in the caller's
//! arena (slices point into `src` or arena allocations; free the arena, free
//! the doc).
//!
//! The block grammar (a practical GFM subset plus strikedown additions):
//!   - ATX headings (`#` .. `######`) with auto anchor ids (see `slugify`)
//!   - paragraphs (soft-wrapped lines are joined with a space)
//!   - unordered (`-`/`*`/`+`) and ordered (`1.`) lists, nested by
//!     indentation, with `- [ ]`/`- [x]` task boxes
//!   - GFM pipe tables (header + `|---|` separator, `:-:` alignment)
//!   - fenced code blocks (```` ``` ````) with an info-string language
//!   - blockquotes (`>`), horizontal rules (`---` / `***` / `___`)
//!   - display math `$$…$$` (TeX kept raw; emitters decide the wrapping)
//!   - typography directives (`:color brand #7c3aed`) — consumed, no block;
//!     they extend the document's working `Sheet` from that line on
//!   - a `(alias)` block prefix (`(brand)# Title`) coloring the block it
//!     starts — recognized **only** when the alias resolves in the working
//!     sheet, so unstyled documents render byte-identically to plain markdown
//!
//! Inline grammar, in precedence order: backslash escape, `` `code` ``,
//! `$math$`, `![alt](src)`, `[text](url)`, `<http…>` and bare-URL autolinks,
//! `***`/`**`/`*` emphasis, `~~strikethrough~~`. Code/math bodies are never
//! inline-parsed.
//!
//! Typography lands as *attributes on tree nodes* (e.g. `Block.color`), never
//! as emitter special cases. Every superset form must degrade to inert prose
//! in plain markdown documents that never activate it.

const std = @import("std");
const sheet = @import("sheet.zig");
const Allocator = std.mem.Allocator;

// ---- document model ----------------------------------------------------------

pub const Doc = struct {
    blocks: []Block,
};

/// One block-level element. Typography attributes live here, beside the
/// structural payload in `kind`, so every block type gets them uniformly.
pub const Block = struct {
    /// Resolved CSS color (e.g. "#7c3aed") from a `(alias)` block prefix;
    /// null = unstyled. Emitters that have no color channel may ignore it.
    color: ?[]const u8 = null,
    kind: Kind,

    pub const Kind = union(enum) {
        heading: Heading,
        paragraph: []Inline,
        /// One entry per `>` line, each its own paragraph inside the quote.
        quote: [][]Inline,
        list: List,
        code: Code,
        table: Table,
        /// Raw display-math TeX (multi-line joined with '\n'), not escaped.
        math: []const u8,
        rule,
    };
};

pub const Heading = struct {
    level: usize, // 1..6
    id: []const u8, // slugified anchor, deduped per document
    inlines: []Inline,
};

pub const Code = struct {
    lang: []const u8, // "" if the fence had no info string
    text: []const u8, // verbatim body, every line '\n'-terminated
};

pub const List = struct {
    ordered: bool,
    items: []Item,
};

pub const Item = struct {
    /// null = plain item; true/false = checked/unchecked task box.
    task: ?bool = null,
    /// The marker line's inline content.
    text: []Inline,
    /// Continuation segments in source order: soft-wrapped lines and nested lists.
    tail: []Tail = &.{},

    pub const Tail = union(enum) {
        line: []Inline,
        list: List,
    };
};

pub const Table = struct {
    /// Per-column alignment from the separator row (may be shorter/longer than
    /// the header; index with `alignAt`).
    aligns: []Align,
    header: [][]Inline,
    /// Body rows, each already padded/truncated to `header.len` cells.
    rows: [][][]Inline,
};

pub const Align = enum { none, left, center, right };

pub const Inline = union(enum) {
    /// Literal text (backslash escapes already unwrapped). Emitters escape it.
    text: []const u8,
    code: []const u8,
    /// Raw inline-math TeX.
    math: []const u8,
    image: struct { src: []const u8, alt: []const u8 },
    link: struct { url: []const u8, children: []Inline },
    /// A URL that is both target and label (`<http…>` or a bare URL).
    autolink: []const u8,
    strong: []Inline,
    em: []Inline,
    strong_em: []Inline,
    strike: []Inline,
};

pub fn alignAt(aligns: []const Align, i: usize) Align {
    return if (i < aligns.len) aligns[i] else .none;
}

// ---- parsing -----------------------------------------------------------------

/// Parse strikedown/markdown source into a `Doc`. `base` seeds the document's
/// working sheet (the site/project `.sxh` header, or `.empty`); in-document
/// directives extend it as they are consumed. Everything in the returned tree
/// is owned by `arena` (or points into `src`/`base`) — free the arena as a
/// whole, never nodes piecemeal.
pub fn parse(arena: Allocator, src: []const u8, base: sheet.Sheet) Allocator.Error!Doc {
    // Collect the document into lines so block parsers can look ahead.
    var lines: std.ArrayList([]const u8) = .empty;
    {
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| {
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try lines.append(arena, line);
        }
    }

    var p: Parser = .{ .arena = arena, .lines = lines.items };
    try p.colors.appendSlice(arena, base.colors);
    var blocks: std.ArrayList(Block) = .empty;
    while (p.idx < p.lines.len) {
        if (isBlank(p.lines[p.idx])) {
            p.idx += 1;
            continue;
        }
        if (try p.next()) |block| try blocks.append(arena, block);
    }
    return .{ .blocks = try blocks.toOwnedSlice(arena) };
}

const Parser = struct {
    arena: Allocator,
    /// Mutable so a recognized `(alias)` prefix can be stripped in place,
    /// letting the multi-line block parsers see the plain construct.
    lines: [][]const u8,
    idx: usize = 0,
    /// Heading anchor slugs used so far in this document (for deduping).
    used_slugs: std.ArrayList([]const u8) = .empty,
    /// The working sheet: the base (site/project header) entries followed by
    /// every in-document directive consumed so far. Later entries win.
    colors: std.ArrayList(sheet.Sheet.Entry) = .empty,

    /// Parse the block starting at `idx` (which is non-blank), advancing past
    /// it. Returns null for lines consumed without producing a block
    /// (typography directives).
    fn next(p: *Parser) Allocator.Error!?Block {
        const t = std.mem.trimStart(u8, p.lines[p.idx], " ");

        // Typography directive: extends the working sheet, emits nothing.
        if (sheet.parseLine(t)) |directive| {
            switch (directive) {
                .color => |entry| try p.colors.append(p.arena, entry),
            }
            p.idx += 1;
            return null;
        }

        // `(alias)` color prefix. Strip it in place, parse the rest as any
        // normal block, and attach the resolved color — uniform across block
        // types, no per-block special cases.
        if (p.splitColorPrefix(t)) |pre| {
            p.lines[p.idx] = pre.rest;
            var block = try p.parseBlock(pre.rest);
            block.color = pre.color;
            return block;
        }

        return try p.parseBlock(t);
    }

    /// If `t` starts with a `(alias)` prefix whose alias resolves in the
    /// working sheet, return the resolved color and the rest of the line.
    /// An undefined alias returns null and the line stays literal prose —
    /// the superset's backward-compatibility rule.
    fn splitColorPrefix(p: *Parser, t: []const u8) ?struct { color: []const u8, rest: []const u8 } {
        if (t.len < 3 or t[0] != '(') return null;
        const close = std.mem.indexOfScalar(u8, t, ')') orelse return null;
        const name = t[1..close];
        if (!sheet.isAliasName(name)) return null;
        const value = p.lookupColor(name) orelse return null;
        return .{ .color = value, .rest = std.mem.trimStart(u8, t[close + 1 ..], " ") };
    }

    fn lookupColor(p: *Parser, name: []const u8) ?[]const u8 {
        const working: sheet.Sheet = .{ .colors = p.colors.items };
        return working.lookup(name);
    }

    /// The block classification chain: `t` is the current line, left-trimmed
    /// (and prefix-stripped, when a color prefix applied).
    fn parseBlock(p: *Parser, t: []const u8) Allocator.Error!Block {
        const arena = p.arena;

        // Fenced code block: contents are kept verbatim, no inline parsing.
        if (std.mem.startsWith(u8, t, "```")) {
            // Info string: the first token names the language (```python);
            // anything after it is ignored.
            const info = std.mem.trim(u8, t[3..], " ");
            const lang = info[0 .. std.mem.indexOfScalar(u8, info, ' ') orelse info.len];
            p.idx += 1;
            var buf: std.ArrayList(u8) = .empty;
            while (p.idx < p.lines.len and
                !std.mem.startsWith(u8, std.mem.trimStart(u8, p.lines[p.idx], " "), "```"))
            {
                try buf.appendSlice(arena, p.lines[p.idx]);
                try buf.append(arena, '\n');
                p.idx += 1;
            }
            if (p.idx < p.lines.len) p.idx += 1; // consume the closing fence
            return .{ .kind = .{ .code = .{ .lang = lang, .text = try buf.toOwnedSlice(arena) } } };
        }

        // Display math: `$$…$$`. The TeX is kept raw; emitters wrap it.
        if (std.mem.startsWith(u8, t, "$$")) {
            const rest = std.mem.trimEnd(u8, t, " ");
            // Single-line `$$ … $$`.
            if (rest.len >= 4 and std.mem.endsWith(u8, rest, "$$")) {
                p.idx += 1;
                return .{ .kind = .{ .math = rest[2 .. rest.len - 2] } };
            }
            // Multi-line: gather until a line ending in `$$`.
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, std.mem.trimStart(u8, rest, "$"));
            p.idx += 1;
            while (p.idx < p.lines.len) {
                const ml = std.mem.trimEnd(u8, p.lines[p.idx], " ");
                try buf.append(arena, '\n');
                if (std.mem.endsWith(u8, ml, "$$")) {
                    try buf.appendSlice(arena, ml[0 .. ml.len - 2]);
                    p.idx += 1;
                    break;
                }
                try buf.appendSlice(arena, ml);
                p.idx += 1;
            }
            return .{ .kind = .{ .math = try buf.toOwnedSlice(arena) } };
        }

        // ATX heading. The anchor id comes from the raw heading text (markdown
        // punctuation collapses into `-` naturally), deduped per document.
        if (headingLevel(t)) |level| {
            const text = std.mem.trim(u8, t[level..], " ");
            const slug = try p.uniqueSlug(text);
            p.idx += 1;
            return .{ .kind = .{ .heading = .{
                .level = level,
                .id = slug,
                .inlines = try parseInlines(arena, text),
            } } };
        }

        // Horizontal rule (checked before lists so `---` is not a list item).
        if (isHorizontalRule(t)) {
            p.idx += 1;
            return .{ .kind = .rule };
        }

        // Blockquote: a run of consecutive `>` lines.
        if (std.mem.startsWith(u8, t, ">")) {
            var qlines: std.ArrayList([]Inline) = .empty;
            while (p.idx < p.lines.len) {
                const qt = std.mem.trimStart(u8, p.lines[p.idx], " ");
                if (!std.mem.startsWith(u8, qt, ">")) break;
                var content = qt[1..];
                if (content.len > 0 and content[0] == ' ') content = content[1..];
                try qlines.append(arena, try parseInlines(arena, std.mem.trimEnd(u8, content, " ")));
                p.idx += 1;
            }
            return .{ .kind = .{ .quote = try qlines.toOwnedSlice(arena) } };
        }

        // List (unordered or ordered, possibly nested by indentation).
        if (parseMarker(t) != null) {
            return .{ .kind = .{ .list = try p.parseList() } };
        }

        // GFM pipe table: a header row followed by a `|---|` separator row.
        if (isTableStart(p.lines, p.idx)) {
            var header_cells: std.ArrayList([]const u8) = .empty;
            try splitCells(arena, &header_cells, std.mem.trimStart(u8, p.lines[p.idx], " "));
            var aligns: std.ArrayList(Align) = .empty;
            try parseAligns(arena, &aligns, std.mem.trimStart(u8, p.lines[p.idx + 1], " "));
            p.idx += 2;

            var header: std.ArrayList([]Inline) = .empty;
            for (header_cells.items) |cell| try header.append(arena, try parseInlines(arena, cell));

            var rows: std.ArrayList([][]Inline) = .empty;
            var row_cells: std.ArrayList([]const u8) = .empty;
            while (p.idx < p.lines.len) {
                const rt = std.mem.trimStart(u8, p.lines[p.idx], " ");
                if (isBlank(p.lines[p.idx]) or isBlockStart(rt) or
                    std.mem.indexOfScalar(u8, rt, '|') == null) break;
                row_cells.clearRetainingCapacity();
                try splitCells(arena, &row_cells, rt);
                // GFM: pad/truncate every body row to the header's column count.
                const row = try arena.alloc([]Inline, header.items.len);
                for (row, 0..) |*cell, ci| {
                    cell.* = try parseInlines(arena, if (ci < row_cells.items.len) row_cells.items[ci] else "");
                }
                try rows.append(arena, row);
                p.idx += 1;
            }
            return .{ .kind = .{ .table = .{
                .aligns = try aligns.toOwnedSlice(arena),
                .header = try header.toOwnedSlice(arena),
                .rows = try rows.toOwnedSlice(arena),
            } } };
        }

        // Paragraph: gather consecutive lines until a blank line or a new block.
        var inls: std.ArrayList(Inline) = .empty;
        try inls.appendSlice(arena, try parseInlines(arena, std.mem.trimEnd(u8, t, " ")));
        p.idx += 1;
        while (p.idx < p.lines.len and !isBlank(p.lines[p.idx])) {
            const nt = std.mem.trim(u8, p.lines[p.idx], " ");
            // `isTableStart` is the table's paragraph-interrupt companion to
            // `isBlockStart` (a table is a two-line pattern, so it can't live
            // there); `splitColorPrefix` is the color prefix's (it needs the
            // working sheet, which `isBlockStart` can't see).
            if (isBlockStart(nt) or isTableStart(p.lines, p.idx) or
                p.splitColorPrefix(nt) != null) break;
            try inls.append(arena, .{ .text = " " });
            try inls.appendSlice(arena, try parseInlines(arena, nt));
            p.idx += 1;
        }
        return .{ .kind = .{ .paragraph = try inls.toOwnedSlice(arena) } };
    }

    /// Parse one (possibly nested) list starting at `idx`, advancing past the
    /// consumed lines. Nesting is by indentation: an item indented >= 2 columns
    /// past its parent opens a child list inside the parent's item; a dedent
    /// returns to the outer level; a marker of the other orderedness at the
    /// same level ends this list (the block loop starts the sibling). An
    /// indented non-marker line soft-wraps into the open item; an unindented
    /// one — or a blank line — ends the list (loose lists are out of scope).
    fn parseList(p: *Parser) Allocator.Error!List {
        const arena = p.arena;
        const base = indentWidth(p.lines[p.idx]);
        const first = parseMarker(std.mem.trimStart(u8, p.lines[p.idx], " \t")) orelse unreachable;
        const ordered = first.ordered;
        var items: std.ArrayList(Item) = .empty;
        var tail: std.ArrayList(Item.Tail) = .empty;
        while (p.idx < p.lines.len) {
            const line = p.lines[p.idx];
            if (isBlank(line)) break;
            const ind = indentWidth(line);
            const t = std.mem.trimStart(u8, line, " \t");
            if (parseMarker(t)) |m| {
                if (ind >= base + 2) {
                    if (items.items.len == 0) break;
                    try tail.append(arena, .{ .list = try p.parseList() });
                    continue;
                }
                if (ind < base or m.ordered != ordered) break;
                if (items.items.len > 0)
                    items.items[items.items.len - 1].tail = try tail.toOwnedSlice(arena);
                try items.append(arena, .{
                    .task = m.task,
                    .text = try parseInlines(arena, std.mem.trimEnd(u8, t[m.content_start..], " ")),
                });
                p.idx += 1;
                continue;
            }
            // Non-marker line: an indented one continues the open item; anything
            // else ends the list (the block loop decides what it is).
            if (items.items.len > 0 and ind > base and !isBlockStart(t) and
                p.splitColorPrefix(t) == null)
            {
                try tail.append(arena, .{ .line = try parseInlines(arena, std.mem.trimEnd(u8, t, " ")) });
                p.idx += 1;
                continue;
            }
            break;
        }
        if (items.items.len > 0)
            items.items[items.items.len - 1].tail = try tail.toOwnedSlice(arena);
        return .{ .ordered = ordered, .items = try items.toOwnedSlice(arena) };
    }

    /// `slugify` plus per-document deduplication: a repeated heading gets a
    /// `-2`, `-3`, … suffix.
    fn uniqueSlug(p: *Parser, text: []const u8) Allocator.Error![]const u8 {
        const base = try slugify(p.arena, text);
        if (!slugInUse(p.used_slugs.items, base)) {
            try p.used_slugs.append(p.arena, base);
            return base;
        }
        var n: usize = 2;
        while (true) : (n += 1) {
            const candidate = try std.fmt.allocPrint(p.arena, "{s}-{d}", .{ base, n });
            if (!slugInUse(p.used_slugs.items, candidate)) {
                try p.used_slugs.append(p.arena, candidate);
                return candidate;
            }
        }
    }
};

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

fn slugInUse(used: []const []const u8, slug: []const u8) bool {
    for (used) |s| if (std.mem.eql(u8, s, slug)) return true;
    return false;
}

// ---- block helpers -----------------------------------------------------------

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// Returns true if a (left-trimmed) line begins any block other than a
/// paragraph. Two block forms are NOT covered here and need companion checks
/// wherever context allows them: pipe tables (a two-line pattern —
/// `isTableStart(lines, idx)`) and `(alias)` color prefixes (they need the
/// working sheet — `Parser.splitColorPrefix`).
fn isBlockStart(t: []const u8) bool {
    return headingLevel(t) != null or
        isHorizontalRule(t) or
        std.mem.startsWith(u8, t, ">") or
        std.mem.startsWith(u8, t, "```") or
        std.mem.startsWith(u8, t, "$$") or
        isUnorderedItem(t) or
        orderedMarkerLen(t) != null or
        sheet.parseLine(t) != null;
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

/// Length of an ordered-list marker like `12. `, or null if the line isn't one.
fn orderedMarkerLen(t: []const u8) ?usize {
    var n: usize = 0;
    while (n < t.len and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0) return null;
    if (n + 1 < t.len and t[n] == '.' and t[n + 1] == ' ') return n + 2;
    return null;
}

// ---- table helpers -----------------------------------------------------------

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
/// inside a cell for the inline parser's escape handling to unwrap later.
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

/// Parse one line's inline markdown into a run of `Inline` nodes. Literal
/// characters (and unwrapped backslash escapes) accumulate into `.text` runs;
/// structured forms flush the run and append their own node. Recurses for
/// nestable content (link text, emphasis bodies).
fn parseInlines(arena: Allocator, text: []const u8) Allocator.Error![]Inline {
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

        // `inline code` — highest precedence, no nested parsing.
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .code = text[i + 1 .. end] });
                i = end + 1;
                continue;
            }
        }

        // $inline math$ — raw TeX; no markdown applies inside.
        if (c == '$') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '$')) |end| {
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

        // ***bold italic*** — checked before **bold** so the third star isn't
        // left over as a literal character.
        if (c == '*' and i + 2 < text.len and text[i + 1] == '*' and text[i + 2] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 3, "***")) |end| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .strong_em = try parseInlines(arena, text[i + 3 .. end]) });
                i = end + 3;
                continue;
            }
        }

        // **bold**
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try flushText(arena, &out, &pending);
                try out.append(arena, .{ .strong = try parseInlines(arena, text[i + 2 .. end]) });
                i = end + 2;
                continue;
            }
        }

        // *italic*
        if (c == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                if (end > i + 1) {
                    try flushText(arena, &out, &pending);
                    try out.append(arena, .{ .em = try parseInlines(arena, text[i + 1 .. end]) });
                    i = end + 1;
                    continue;
                }
            }
        }

        // ~~strikethrough~~
        if (c == '~' and i + 1 < text.len and text[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
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

// ---- tests -------------------------------------------------------------------
// Structural (tree-shape) tests live here; end-to-end source→HTML tests live
// with the emitter in `render_html.zig`.

const testing = std.testing;

test "parse classifies blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\# Title
        \\
        \\a paragraph
        \\
        \\- item
        \\
        \\> quoted
        \\
        \\---
    , .empty);
    try testing.expectEqual(@as(usize, 5), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind == .heading);
    try testing.expect(doc.blocks[1].kind == .paragraph);
    try testing.expect(doc.blocks[2].kind == .list);
    try testing.expect(doc.blocks[3].kind == .quote);
    try testing.expect(doc.blocks[4].kind == .rule);
}

test "heading slugs dedupe per document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "# A\n\n# A\n\n# A", .empty);
    try testing.expectEqualStrings("a", doc.blocks[0].kind.heading.id);
    try testing.expectEqualStrings("a-2", doc.blocks[1].kind.heading.id);
    try testing.expectEqualStrings("a-3", doc.blocks[2].kind.heading.id);
}

test "nested list becomes a tail segment of its parent item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- a\n  - a1\n- b", .empty);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(@as(usize, 1), list.items[0].tail.len);
    try testing.expect(list.items[0].tail[0] == .list);
    try testing.expectEqual(@as(usize, 0), list.items[1].tail.len);
}

test "table rows are padded to the header width at parse time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "| a | b |\n|---|---|\n| 1 |", .empty);
    const table = doc.blocks[0].kind.table;
    try testing.expectEqual(@as(usize, 2), table.header.len);
    try testing.expectEqual(@as(usize, 1), table.rows.len);
    try testing.expectEqual(@as(usize, 2), table.rows[0].len);
    try testing.expectEqual(@as(usize, 0), table.rows[0][1].len); // padded cell is empty
}

test "color directive + prefix attach a resolved color to the block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\:color brand #7c3aed
        \\
        \\(brand)# Title
        \\
        \\plain
    , .empty);
    // the directive line produced no block
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind == .heading);
    try testing.expectEqualStrings("#7c3aed", doc.blocks[0].color.?);
    try testing.expect(doc.blocks[1].color == null);
}

test "base sheet seeds the working sheet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const base: sheet.Sheet = .{ .colors = &.{.{ .name = "soft", .value = "#9aa4b2" }} };
    const doc = try parse(arena_state.allocator(), "(soft)> aside", base);
    try testing.expect(doc.blocks[0].kind == .quote);
    try testing.expectEqualStrings("#9aa4b2", doc.blocks[0].color.?);
}

test "undefined alias prefix stays literal prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "(nope)# not a heading", .empty);
    try testing.expect(doc.blocks[0].kind == .paragraph);
    try testing.expect(doc.blocks[0].color == null);
}

test "slugify" {
    const gpa = testing.allocator;
    const s1 = try slugify(gpa, "Hello, World!");
    defer gpa.free(s1);
    try testing.expectEqualStrings("hello-world", s1);
    const s2 = try slugify(gpa, "  --- ");
    defer gpa.free(s2);
    try testing.expectEqualStrings("section", s2);
    const s3 = try slugify(gpa, "K-Means (k=3)");
    defer gpa.free(s3);
    try testing.expectEqualStrings("k-means-k-3", s3);
}
