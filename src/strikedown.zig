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
//!     indentation, with `- [ ]`/`- [x]` task boxes; a plain line lazily
//!     continues the open item, blank lines between items don't end the
//!     list, and the first written number sets an ordered list's start
//!   - GFM pipe tables (header + `|---|` separator, `:-:` alignment)
//!   - fenced code blocks (```` ``` ````) with an info-string language
//!   - blockquotes (`>`): consecutive `>` lines flow into one paragraph, a
//!     bare `>` line breaks paragraphs, and a plain line lazily continues the
//!     open quote paragraph until a blank line or a new block
//!   - horizontal rules (`---` / `***` / `___`)
//!   - display math `$$…$$` (TeX kept raw; emitters decide the wrapping)
//!   - typography directives (`:` lines) — a reserved namespace, currently
//!     inert (see `sheet.zig`); a recognized line is consumed, emits no block
//!   - group directives (`// two_lists grid(2)` … `// --` … `// end`) —
//!     bracketing content into sections that layout commands arrange (see
//!     `docs/design/001-groups.md`); a `//` line is a directive **iff it
//!     parses cleanly**, otherwise prose
//!   - single-command directives (`/skinny(60%)`) applying one command to the
//!     very next content element (see `docs/design/002-single-command.md`)
//!
//! Inline grammar, in precedence order: backslash escape, `` `code` ``,
//! `$math$`, `![alt](src)`, `[text](url)`, `[text].color(role)` color spans
//! (see `docs/design/006-color.md`), `<http…>` and bare-URL autolinks,
//! `***`/`**`/`*` emphasis, `~~strikethrough~~`. Code/math bodies are never
//! inline-parsed.
//!
//! Layout and typography land as *data on tree nodes* (e.g. `Group.columns`,
//! `Group.text_color`), never as emitter special cases. Every superset form
//! must degrade to inert prose in plain markdown documents that never
//! activate it.

const std = @import("std");
const sheet = @import("sheet.zig");
const Allocator = std.mem.Allocator;

// ---- document model ----------------------------------------------------------

pub const Doc = struct {
    blocks: []Block,
    /// Parse-time diagnostics (e.g. a `grid(n)` section-count mismatch), as
    /// arena strings. `parse` stays pure — callers decide whether to print.
    warnings: []const []const u8 = &.{},
};

/// One block-level element — a *content element*, or a group arranging
/// content elements. Shared attributes (typography, when it returns) will
/// live here beside the structural payload in `kind`, so every block type
/// gets them uniformly.
pub const Block = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        heading: Heading,
        paragraph: []Inline,
        /// The quote's paragraphs: consecutive `>` lines merge into one,
        /// a bare `>` line separates them.
        quote: [][]Inline,
        list: List,
        code: Code,
        table: Table,
        /// Raw display-math TeX (multi-line joined with '\n'), not escaped.
        math: []const u8,
        rule,
        group: Group,
    };
};

/// A group's block: sections of content arranged by its commands. Commands
/// land here as attributes (data, not emitter special cases) — `grid(n)`
/// sets `columns`, `skinny(N%)` sets `width_pct`, `center()` sets
/// `centered`, `color(role)` sets `text_color`; future commands grow more
/// fields. A single-command directive (`/cmd()`) produces this same node:
/// nameless, one section holding the one element it binds to.
pub const Group = struct {
    name: []const u8, // "" = nameless (runs to EOF unless closed)
    columns: ?usize = null, // from grid(n); null = plain stacked container
    width_pct: ?usize = null, // from skinny(N%): % of the body column width
    centered: bool = false, // from center(): center-align contained text
    text_color: ?TextColor = null, // from color(role): theme text color
    sections: [][]Block,
};

/// A theme color role (`docs/design/006-color.md`). Strikedown never names
/// concrete colors — a role resolves to whatever the reader's active theme
/// defines for it (HTML: `var(--accent)` etc.), so colored text tracks theme
/// switches; other backends map roles to their own palettes.
pub const TextColor = enum {
    accent,
    muted,
    fg,

    pub fn parse(name: []const u8) ?TextColor {
        return std.meta.stringToEnum(TextColor, name);
    }
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
    /// The first item's written number (GFM: it sets the list start; later
    /// item numbers are ignored). Always 1 for unordered lists.
    start: usize,
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
    /// `[text].color(role)` — a colored span (`docs/design/006-color.md`).
    color_span: struct { color: TextColor, children: []Inline },
};

pub fn alignAt(aligns: []const Align, i: usize) Align {
    return if (i < aligns.len) aligns[i] else .none;
}

// ---- parsing -----------------------------------------------------------------

/// Parse strikedown/markdown source into a `Doc`. `base` is the document's
/// base typography sheet (the site/project `.sxh` header, or `.empty`) —
/// inert while the directive namespace is reserved, kept so the header
/// plumbing stays wired. Everything in the returned tree is owned by `arena`
/// (or points into `src`) — free the arena as a whole, never nodes piecemeal.
pub fn parse(arena: Allocator, src: []const u8, base: sheet.Sheet) Allocator.Error!Doc {
    _ = base;
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
    var blocks: std.ArrayList(Block) = .empty;
    while (p.idx < p.lines.len) {
        if (isBlank(p.lines[p.idx])) {
            p.idx += 1;
            continue;
        }
        if (try p.next()) |block| try blocks.append(arena, block);
    }
    return .{
        .blocks = try blocks.toOwnedSlice(arena),
        .warnings = try p.warnings.toOwnedSlice(arena),
    };
}

const Parser = struct {
    arena: Allocator,
    lines: []const []const u8,
    idx: usize = 0,
    /// Heading anchor slugs used so far in this document (for deduping).
    used_slugs: std.ArrayList([]const u8) = .empty,
    /// How many groups are open. Separator/closer group lines are only live
    /// inside a group; outside they stay prose (`isGroupInterrupt`).
    group_depth: usize = 0,
    /// How many open groups carry each layout command. The layout-level rule
    /// is per-command (`docs/STRIKEDOWN.md`): a layout command whose counter
    /// is already > 0 — an open ancestor carries the same command — is
    /// ignored with a warning; other commands on the same opener still apply.
    layout_depth: std.enums.EnumArray(std.meta.Tag(Command), usize) = .initFill(0),
    /// Diagnostics collected while parsing (handed to `Doc.warnings`).
    warnings: std.ArrayList([]const u8) = .empty,

    /// Parse the block starting at `idx` (which is non-blank), advancing past
    /// it. Returns null for lines consumed without producing a block
    /// (typography directives).
    fn next(p: *Parser) Allocator.Error!?Block {
        const t = std.mem.trimStart(u8, p.lines[p.idx], " ");

        // Typography directive (`:` line): consumed, emits nothing. The `:`
        // namespace is reserved — `sheet.parseLine` recognizes nothing today
        // — so this arm is dormant until typography directives return.
        if (sheet.parseLine(t) != null) {
            p.idx += 1;
            return null;
        }

        return try p.parseBlock(t);
    }

    /// The block classification chain: `t` is the current line, left-trimmed
    /// (and prefix-stripped, when a color prefix applied).
    fn parseBlock(p: *Parser, t: []const u8) Allocator.Error!Block {
        const arena = p.arena;

        // Group directive. Only a clean *opener* starts anything here; a
        // separator/closer line is consumed inside `parseGroup`'s loop, so one
        // reaching this chain is outside any group (or mismatched) and falls
        // through to prose — the degradation rule.
        if (parseGroupLine(t)) |gl| {
            if (gl == .open) return try p.parseGroup(gl.open);
        }

        // Single-command directive: `/cmd(args)` applies one command to the
        // very next content element by wrapping it in an anonymous group.
        // With nothing to bind to (EOF, or a directive next), it falls
        // through to prose — the same context-liveness rule that keeps
        // separators/closers outside a group inert.
        if (parseSingleCommandLine(t)) |cmd| {
            if (try p.parseSingleCommand(cmd)) |block| return block;
        }

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

        // Blockquote. Consecutive `>` lines soft-merge into one flowing
        // paragraph (the same joining rule as plain paragraphs); a bare `>`
        // line breaks paragraphs within the quote; a plain line lazily
        // continues the open quote paragraph (GFM lazy continuation). A
        // blank line — or any new block form — ends the quote.
        if (std.mem.startsWith(u8, t, ">")) {
            var paras: std.ArrayList([]Inline) = .empty;
            var cur: std.ArrayList(Inline) = .empty;
            while (p.idx < p.lines.len) {
                if (isBlank(p.lines[p.idx])) break;
                const qt = std.mem.trimStart(u8, p.lines[p.idx], " ");
                if (std.mem.startsWith(u8, qt, ">")) {
                    var content = qt[1..];
                    if (content.len > 0 and content[0] == ' ') content = content[1..];
                    content = std.mem.trimEnd(u8, content, " ");
                    if (content.len == 0) {
                        // Bare `>`: paragraph break within the quote.
                        if (cur.items.len > 0) try paras.append(arena, try cur.toOwnedSlice(arena));
                        cur = .empty;
                    } else {
                        if (cur.items.len > 0) try cur.append(arena, .{ .text = " " });
                        try cur.appendSlice(arena, try parseInlines(arena, content));
                    }
                    p.idx += 1;
                    continue;
                }
                // Lazy continuation needs an open paragraph and a line that
                // starts no block.
                if (cur.items.len == 0) break;
                if (p.interruptsFlow(qt)) break;
                try cur.append(arena, .{ .text = " " });
                try cur.appendSlice(arena, try parseInlines(arena, qt));
                p.idx += 1;
            }
            if (cur.items.len > 0) try paras.append(arena, try cur.toOwnedSlice(arena));
            return .{ .kind = .{ .quote = try paras.toOwnedSlice(arena) } };
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
            if (p.interruptsFlow(nt)) break;
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
    /// same level ends this list (the block loop starts the sibling). A
    /// non-marker line that starts no block soft-wraps into the open item,
    /// indented or not (lazy continuation, as in quotes). Blank lines end the
    /// list unless the next non-blank line is a marker continuing it — a
    /// sibling of the same orderedness, or a nested item; rendering stays
    /// tight either way (`<p>`-wrapped loose rendering is out of scope).
    fn parseList(p: *Parser) Allocator.Error!List {
        const arena = p.arena;
        const base = indentWidth(p.lines[p.idx]);
        const first = parseMarker(std.mem.trimStart(u8, p.lines[p.idx], " \t")) orelse unreachable;
        const ordered = first.ordered;
        var items: std.ArrayList(Item) = .empty;
        var tail: std.ArrayList(Item.Tail) = .empty;
        while (p.idx < p.lines.len) {
            const line = p.lines[p.idx];
            if (isBlank(line)) {
                // Skip the blank run iff a marker that continues this list
                // follows; only a marker resumes a list across a blank.
                var j = p.idx;
                while (j < p.lines.len and isBlank(p.lines[j])) j += 1;
                if (j == p.lines.len) break;
                const m = parseMarker(std.mem.trimStart(u8, p.lines[j], " \t")) orelse break;
                const nind = indentWidth(p.lines[j]);
                if (nind < base) break;
                if (nind < base + 2 and m.ordered != ordered) break;
                p.idx = j;
                continue;
            }
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
            // Non-marker line: one that starts no block continues the open
            // item; anything else ends the list (the block loop decides what
            // it is).
            if (items.items.len > 0 and !p.interruptsFlow(t)) {
                try tail.append(arena, .{ .line = try parseInlines(arena, std.mem.trimEnd(u8, t, " ")) });
                p.idx += 1;
                continue;
            }
            break;
        }
        if (items.items.len > 0)
            items.items[items.items.len - 1].tail = try tail.toOwnedSlice(arena);
        return .{ .ordered = ordered, .start = first.num, .items = try items.toOwnedSlice(arena) };
    }

    /// Parse a group: the opener line at `idx` is consumed, then content
    /// blocks accumulate into sections until a separator (`// --`) starts the
    /// next one and a closer (`// end [name]` or bare `//`) — or EOF — ends
    /// the group. Recursion via `next()` makes nested groups work and binds
    /// separators/closers to the innermost group; a closer whose name doesn't
    /// match this group is not consumed here and degrades to prose.
    fn parseGroup(p: *Parser, open: GroupLine.Open) Allocator.Error!Block {
        const arena = p.arena;
        p.idx += 1;
        p.group_depth += 1;
        defer p.group_depth -= 1;
        // The layout-level rule, per command: a layout command an open
        // ancestor already carries is stripped with a warning; the rest of
        // the opener still applies, and the group still forms (structure
        // kept — degradation stays gentle).
        var attrs = open;
        try p.stripNestedLayout(&attrs, attrs.name);
        p.enterLayout(attrs);
        defer p.exitLayout(attrs);
        var sections: std.ArrayList([]Block) = .empty;
        var cur: std.ArrayList(Block) = .empty;
        while (p.idx < p.lines.len) {
            if (isBlank(p.lines[p.idx])) {
                p.idx += 1;
                continue;
            }
            const t = std.mem.trimStart(u8, p.lines[p.idx], " ");
            if (parseGroupLine(t)) |gl| switch (gl) {
                .sep => {
                    p.idx += 1;
                    try sections.append(arena, try cur.toOwnedSlice(arena));
                    cur = .empty;
                    continue;
                },
                .bare => {
                    p.idx += 1;
                    break;
                },
                .end => |name| if (name == null or std.mem.eql(u8, name.?, attrs.name)) {
                    p.idx += 1;
                    break;
                },
                .open => {}, // a nested group; `next()` below recurses into it
            };
            if (try p.next()) |block| try cur.append(arena, block);
        }
        try sections.append(arena, try cur.toOwnedSlice(arena));
        if (attrs.columns) |n| if (sections.items.len != n) {
            try p.warnings.append(arena, try std.fmt.allocPrint(
                arena,
                "group '{s}': grid({d}) but {d} section(s)",
                .{ groupLabel(attrs.name), n, sections.items.len },
            ));
        };
        return .{ .kind = .{ .group = .{
            .name = attrs.name,
            .columns = attrs.columns,
            .width_pct = attrs.width_pct,
            .centered = attrs.centered,
            .text_color = attrs.text_color,
            .sections = try sections.toOwnedSlice(arena),
        } } };
    }

    /// Apply a single-command directive: wrap the very next content element
    /// in an anonymous one-section group — the same tree node and emitter
    /// path as `//` groups. Returns null (the line stays prose) when there is
    /// nothing to bind to: EOF, or a `:`/`//` directive next. A chain of
    /// `/command()` lines recurses — each wraps the next, down to the
    /// eventual content element — so `/skinny() /color(accent) text` nests
    /// exactly as the equivalent nested groups would (layout-level rule and
    /// all: a repeated layout command in the chain still strips and warns).
    fn parseSingleCommand(p: *Parser, cmd: Command) Allocator.Error!?Block {
        const arena = p.arena;
        const saved_idx = p.idx;
        var j = p.idx + 1;
        while (j < p.lines.len and isBlank(p.lines[j])) j += 1;
        if (j >= p.lines.len) return null;
        const nt = std.mem.trimStart(u8, p.lines[j], " ");
        if (p.isGroupInterrupt(nt) or sheet.parseLine(nt) != null) return null;

        var attrs: GroupLine.Open = .{ .name = "" };
        applyCommand(&attrs, cmd);
        // The layout-level rule, exactly as in `parseGroup`.
        try p.stripNestedLayout(&attrs, null);
        if (attrs.columns) |n| if (n != 1) {
            try p.warnings.append(arena, try std.fmt.allocPrint(
                arena,
                "single command: grid({d}) but 1 element",
                .{n},
            ));
        };

        p.idx = j;
        p.enterLayout(attrs);
        defer p.exitLayout(attrs);
        // A chained `/command()` line binds recursively; if the chain never
        // reaches a content element (EOF/directive at its end), the whole
        // thing reverts to prose — restore `idx` so the caller re-parses
        // this line as such, rather than resuming mid-chain.
        const inner = if (parseSingleCommandLine(nt)) |next_cmd|
            (try p.parseSingleCommand(next_cmd)) orelse {
                p.idx = saved_idx;
                return null;
            }
        else
            try p.parseBlock(nt);

        const section = try arena.alloc(Block, 1);
        section[0] = inner;
        const sections = try arena.alloc([]Block, 1);
        sections[0] = section;
        return .{ .kind = .{ .group = .{
            .name = "",
            .columns = attrs.columns,
            .width_pct = attrs.width_pct,
            .centered = attrs.centered,
            .text_color = attrs.text_color,
            .sections = sections,
        } } };
    }

    /// The layout-level rule, per command (`docs/STRIKEDOWN.md`): null out
    /// each layout command in `attrs` that an open ancestor already carries,
    /// warning per stripped command. `name` is the group's name for the
    /// warning (null for a single-command directive). Commands that don't
    /// collide survive — the rule strips commands, never openers.
    fn stripNestedLayout(p: *Parser, attrs: *GroupLine.Open, name: ?[]const u8) Allocator.Error!void {
        if (attrs.columns != null and p.layout_depth.get(.grid) > 0) {
            attrs.columns = null;
            try p.warnStrippedLayout(name, "grid");
        }
        if (attrs.width_pct != null and p.layout_depth.get(.skinny) > 0) {
            attrs.width_pct = null;
            try p.warnStrippedLayout(name, "skinny");
        }
        if (attrs.centered and p.layout_depth.get(.center) > 0) {
            attrs.centered = false;
            try p.warnStrippedLayout(name, "center");
        }
    }

    fn warnStrippedLayout(p: *Parser, name: ?[]const u8, cmd: []const u8) Allocator.Error!void {
        try p.warnings.append(p.arena, if (name) |n|
            try std.fmt.allocPrint(
                p.arena,
                "group '{s}': {s} ignored (already inside a {s})",
                .{ groupLabel(n), cmd, cmd },
            )
        else
            try std.fmt.allocPrint(
                p.arena,
                "single command: {s} ignored (already inside a {s})",
                .{ cmd, cmd },
            ));
    }

    /// Count the layout commands `attrs` carries (post-strip) as open, for
    /// the per-command rule. Pair with a deferred `exitLayout` on the same
    /// attrs. Future non-layout commands simply won't touch a counter.
    fn enterLayout(p: *Parser, attrs: GroupLine.Open) void {
        if (attrs.columns != null) p.layout_depth.getPtr(.grid).* += 1;
        if (attrs.width_pct != null) p.layout_depth.getPtr(.skinny).* += 1;
        if (attrs.centered) p.layout_depth.getPtr(.center).* += 1;
    }

    fn exitLayout(p: *Parser, attrs: GroupLine.Open) void {
        if (attrs.columns != null) p.layout_depth.getPtr(.grid).* -= 1;
        if (attrs.width_pct != null) p.layout_depth.getPtr(.skinny).* -= 1;
        if (attrs.centered) p.layout_depth.getPtr(.center).* -= 1;
    }

    /// True if the line at `idx` (already left-trimmed as `t`) starts a new
    /// block form — `isBlockStart` plus its two contextual companions (pipe
    /// tables and group directives). The one shared "does this line interrupt
    /// a flowing text run" check, used by the paragraph loop, quote lazy
    /// continuation, and list item continuation.
    fn interruptsFlow(p: *Parser, t: []const u8) bool {
        return isBlockStart(t) or isTableStart(p.lines, p.idx) or p.isGroupInterrupt(t);
    }

    /// The group directive's paragraph-interrupt companion to `isBlockStart`
    /// (it needs parser state, so it can't live there): a clean opener is live
    /// anywhere; separator/closer forms only while a group is open. Inert `//`
    /// prose lines keep soft-wrapping into paragraphs as in plain markdown.
    fn isGroupInterrupt(p: *Parser, t: []const u8) bool {
        const gl = parseGroupLine(t) orelse return false;
        return switch (gl) {
            .open => true,
            .sep, .end, .bare => p.group_depth > 0,
        };
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
/// paragraph. Two block forms are NOT covered here and need context: pipe
/// tables (a two-line pattern — `isTableStart(lines, idx)`) and group
/// directives (they need the open-group depth — `Parser.isGroupInterrupt`);
/// `Parser.interruptsFlow` bundles all three and is what flowing-text loops
/// call. A clean single-command line counts even when its follower later
/// makes it inert prose — a small accepted divergence
/// (`docs/design/002-single-command.md`) that keeps this check context-free.
fn isBlockStart(t: []const u8) bool {
    return headingLevel(t) != null or
        isHorizontalRule(t) or
        std.mem.startsWith(u8, t, ">") or
        std.mem.startsWith(u8, t, "```") or
        std.mem.startsWith(u8, t, "$$") or
        isUnorderedItem(t) or
        orderedMarker(t) != null or
        parseSingleCommandLine(t) != null or
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
    /// The written number (`12. ` -> 12); 1 for unordered markers.
    num: usize,
    /// null = plain item; true/false = checked/unchecked task box.
    task: ?bool,
};

/// Parse a list-item marker (`- `, `* `, `+ `, `12. `) at the start of a
/// left-trimmed line, plus an optional `[ ]`/`[x]` task box after it.
fn parseMarker(t: []const u8) ?Marker {
    var m: Marker = undefined;
    if (isUnorderedItem(t)) {
        m = .{ .ordered = false, .content_start = 2, .num = 1, .task = null };
    } else if (orderedMarker(t)) |om| {
        m = .{ .ordered = true, .content_start = om.len, .num = om.num, .task = null };
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

const OrderedMarker = struct {
    /// Marker length through the space after the dot (`12. ` -> 4).
    len: usize,
    /// The written number.
    num: usize,
};

/// An ordered-list marker like `12. ` at the start of a left-trimmed line,
/// or null if the line isn't one. GFM caps the number at 9 digits.
fn orderedMarker(t: []const u8) ?OrderedMarker {
    var n: usize = 0;
    while (n < t.len and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0 or n > 9) return null;
    if (n + 1 < t.len and t[n] == '.' and t[n + 1] == ' ')
        return .{ .len = n + 2, .num = std.fmt.parseInt(usize, t[0..n], 10) catch unreachable };
    return null;
}

// ---- group directives ----------------------------------------------------------

/// One classified group-directive line (`docs/design/001-groups.md`).
const GroupLine = union(enum) {
    open: Open,
    /// `// --`: the innermost open group's next section starts.
    sep,
    /// `// end` / `// end <name>`: closes the innermost group (a given name
    /// must match it).
    end: ?[]const u8,
    /// Bare `//`: same as `// end`.
    bare,

    const Open = struct {
        name: []const u8, // "" = nameless
        columns: ?usize = null, // from grid(n)
        width_pct: ?usize = null, // from skinny(N%)
        centered: bool = false, // from center()
        text_color: ?TextColor = null, // from color(role)
    };
};

/// Classify a (left-trimmed) line as a group directive, or null if it isn't
/// one — and null is the whole degradation story: any `//` line that does not
/// parse cleanly (unknown command, malformed args, bad name) stays literal
/// prose, so documents that never activate groups render as plain markdown.
///
/// Grammar: `//` must be followed by a space or end-of-line (`//foo` is
/// prose). An opener is `// [name] <command>*` where the name is a bare
/// alias-safe token (`end` and `--` are reserved) and every command is
/// `word(args)` — parens required, so future command keywords can never
/// collide with names. Whether a separator/closer is *live* is the parser's
/// call (they need an open group); this function only classifies.
fn parseGroupLine(t: []const u8) ?GroupLine {
    if (!std.mem.startsWith(u8, t, "//")) return null;
    if (t.len > 2 and t[2] != ' ') return null;
    const rest = std.mem.trim(u8, t[2..], " ");
    if (rest.len == 0) return .bare;
    if (std.mem.eql(u8, rest, "--")) return .sep;

    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const first = it.next() orelse return .bare;
    if (std.mem.eql(u8, first, "end")) {
        const name = it.next() orelse return .{ .end = null };
        if (it.next() != null) return null;
        if (!sheet.isAliasName(name)) return null;
        return .{ .end = name };
    }

    var open: GroupLine.Open = .{ .name = "", .columns = null };
    if (parseCommand(first)) |cmd| {
        applyCommand(&open, cmd);
    } else {
        if (!sheet.isAliasName(first) or std.mem.eql(u8, first, "--")) return null;
        open.name = first;
    }
    while (it.next()) |tok| {
        applyCommand(&open, parseCommand(tok) orelse return null);
    }
    return .{ .open = open };
}

/// The recognized commands. A new command is a variant here, a
/// `parseCommand` arm, an attribute on `Group` via `applyCommand`, and the
/// emitter reading it — data all the way, per the extension recipe. A
/// *layout* command creates a layout element, and its tag keys a
/// `Parser.layout_depth` counter for the per-command layout-level rule
/// (`stripNestedLayout`/`enterLayout`); a non-layout command (`color`)
/// simply never touches a counter, so it nests freely.
const Command = union(enum) {
    grid: usize,
    /// skinny(N%): render at N% of the body column width, centered.
    skinny: usize,
    /// center(): center-align text within the surrounding layout element.
    center,
    /// color(role): set the contained text's theme color. Non-layout —
    /// nested colors are meaningful (inner wins by cascade).
    color: TextColor,
};

/// Parse one `word(args)` token, null if it isn't a recognized command with
/// valid args (which deactivates the whole line — strict, so typos are seen).
fn parseCommand(tok: []const u8) ?Command {
    if (tok.len < 3 or tok[tok.len - 1] != ')') return null;
    const paren = std.mem.indexOfScalar(u8, tok, '(') orelse return null;
    const word = tok[0..paren];
    const args = tok[paren + 1 .. tok.len - 1];
    if (std.mem.eql(u8, word, "grid")) {
        const n = std.fmt.parseInt(usize, args, 10) catch return null;
        if (n == 0) return null;
        return .{ .grid = n };
    }
    if (std.mem.eql(u8, word, "skinny")) {
        if (args.len == 0) return .{ .skinny = 75 }; // bare skinny(): the default width
        if (args[args.len - 1] != '%') return null;
        const n = std.fmt.parseInt(usize, args[0 .. args.len - 1], 10) catch return null;
        if (n == 0 or n > 100) return null;
        return .{ .skinny = n };
    }
    if (std.mem.eql(u8, word, "center")) {
        if (args.len != 0) return null; // center() takes no arguments
        return .center;
    }
    if (std.mem.eql(u8, word, "color")) {
        const role = TextColor.parse(args) orelse return null;
        return .{ .color = role };
    }
    return null;
}

fn applyCommand(open: *GroupLine.Open, cmd: Command) void {
    switch (cmd) {
        .grid => |n| open.columns = n,
        .skinny => |n| open.width_pct = n,
        .center => open.centered = true,
        .color => |role| open.text_color = role,
    }
}

fn groupLabel(name: []const u8) []const u8 {
    return if (name.len > 0) name else "(nameless)";
}

/// Classify a (left-trimmed) line as a single-command directive
/// (`docs/design/002-single-command.md`): `/` immediately followed by exactly
/// one command token and nothing else. The char after the slash keeps the two
/// directive families apart (`//` is a group line), and `parseCommand`'s
/// strictness is the degradation story — `/usr/bin/env`, `/skinny (50%)`, or
/// trailing words all return null and stay prose.
fn parseSingleCommandLine(t: []const u8) ?Command {
    if (t.len < 2 or t[0] != '/' or t[1] == '/') return null;
    return parseCommand(std.mem.trimEnd(u8, t[1..], " "));
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

const ColorSpan = struct { text: []const u8, color: TextColor, consumed: usize };

/// Parse `[text].color(role)` starting at the leading `[`
/// (`docs/design/006-color.md`). Same first-`]` scan as `parseLink` — which
/// is the restriction story: a link's `[label](url)` wins the `[` first, so
/// `.color()` never attaches to a link, and spans don't nest (the earliest
/// `].color(` closes the span; the rest stays literal). Unknown roles fail
/// the parse and stay literal prose.
fn parseColorSpan(s: []const u8) ?ColorSpan {
    const close_bracket = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    const suffix = s[close_bracket + 1 ..];
    if (!std.mem.startsWith(u8, suffix, ".color(")) return null;
    const args_start = close_bracket + 1 + ".color(".len;
    const close_paren = std.mem.indexOfScalarPos(u8, s, args_start, ')') orelse return null;
    const role = TextColor.parse(s[args_start..close_paren]) orelse return null;
    return .{
        .text = s[1..close_bracket],
        .color = role,
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

test "list: an unindented plain line lazily continues the open item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- a\nwraps", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(usize, 1), list.items[0].tail.len);
    try testing.expect(list.items[0].tail[0] == .line);
}

test "list: blank lines between same-orderedness items don't end the list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "1. a\n2. b\n\n3. c", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const list = doc.blocks[0].kind.list;
    try testing.expect(list.ordered);
    try testing.expectEqual(@as(usize, 1), list.start);
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "list: a blank line then the other orderedness still splits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "1. a\n\n- b", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind.list.ordered);
    try testing.expect(!doc.blocks[1].kind.list.ordered);
}

test "list: a blank line then a nested marker continues the open item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- a\n\n  - a1", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(usize, 1), list.items[0].tail.len);
    try testing.expect(list.items[0].tail[0] == .list);
}

test "list: a blank line then plain text ends the list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- a\n\ntext", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind == .list);
    try testing.expect(doc.blocks[1].kind == .paragraph);
}

test "list: the first written number sets the ordered start" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "3. a\n7. b", .empty);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 3), list.start);
    try testing.expectEqual(@as(usize, 2), list.items.len);
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

test "reserved `:` directive lines are prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), ":color brand #7c3aed", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind == .paragraph);
}

test "a (name) block prefix is plain prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "(note)# not a heading", .empty);
    try testing.expect(doc.blocks[0].kind == .paragraph);
}

test "quote: consecutive > lines merge into one paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> a\n> b", .empty);
    const quote = doc.blocks[0].kind.quote;
    try testing.expectEqual(@as(usize, 1), quote.len);
}

test "quote: a bare > line splits paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> a\n>\n> b", .empty);
    const quote = doc.blocks[0].kind.quote;
    try testing.expectEqual(@as(usize, 2), quote.len);
}

test "quote: a plain line lazily continues the quote until a blank line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> a\nb\n\nafter", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].kind.quote.len);
    try testing.expect(doc.blocks[1].kind == .paragraph);
}

test "quote: block forms still interrupt lazy continuation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "> a\n- item", .empty);
    try testing.expectEqual(@as(usize, 2), d1.blocks.len);
    try testing.expect(d1.blocks[0].kind == .quote);
    try testing.expect(d1.blocks[1].kind == .list);
    const d2 = try parse(arena_state.allocator(), "> a\n| h |\n|---|", .empty);
    try testing.expectEqual(@as(usize, 2), d2.blocks.len);
    try testing.expect(d2.blocks[1].kind == .table);
}

test "group directive: the main.sx two-list example" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\// two_lists grid(2)
        \\
        \\1. a
        \\2. b
        \\
        \\// --
        \\
        \\1. c
        \\2. d
        \\
        \\// end two_lists
    , .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const group = doc.blocks[0].kind.group;
    try testing.expectEqualStrings("two_lists", group.name);
    try testing.expectEqual(@as(usize, 2), group.columns.?);
    try testing.expectEqual(@as(usize, 2), group.sections.len);
    try testing.expect(group.sections[0][0].kind == .list);
    try testing.expect(group.sections[1][0].kind == .list);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "group directive: nameless opener runs to EOF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// grid(2)\n\npara a\n\n// --\n\npara b", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const group = doc.blocks[0].kind.group;
    try testing.expectEqualStrings("", group.name);
    try testing.expectEqual(@as(usize, 2), group.sections.len);
}

test "group directive: unterminated named group runs to EOF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// aside\n\npara", .empty);
    const group = doc.blocks[0].kind.group;
    try testing.expectEqualStrings("aside", group.name);
    try testing.expect(group.columns == null);
    try testing.expectEqual(@as(usize, 1), group.sections.len);
}

test "group directive: bare // closes the innermost group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// g\n\na\n\n//\n\nafter", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind == .group);
    try testing.expect(doc.blocks[1].kind == .paragraph);
}

test "group directive: nesting keeps structure but nested layout commands are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\// outer grid(2)
        \\
        \\// inner grid(2)
        \\a
        \\// --
        \\b
        \\// end
        \\
        \\// --
        \\
        \\c
        \\
        \\// end outer
    , .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const outer = doc.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 2), outer.columns.?);
    try testing.expectEqual(@as(usize, 2), outer.sections.len);
    // separators still bind to the innermost group…
    const inner = outer.sections[0][0].kind.group;
    try testing.expectEqualStrings("inner", inner.name);
    try testing.expectEqual(@as(usize, 2), inner.sections.len);
    // …but the layout-level rule strips the grid-in-grid, with a warning.
    try testing.expect(inner.columns == null);
    try testing.expectEqual(@as(usize, 1), doc.warnings.len);
    try testing.expectEqualStrings(
        "group 'inner': grid ignored (already inside a grid)",
        doc.warnings[0],
    );
}

test "layout-level rule is per-command: different commands nest freely" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // a skinny group inside a grid section: both apply, no warnings
    const d1 = try parse(arena_state.allocator(),
        \\// outer grid(2)
        \\
        \\// inner skinny(50%)
        \\a
        \\// end
        \\
        \\// --
        \\
        \\b
        \\
        \\// end outer
    , .empty);
    try testing.expectEqual(@as(usize, 2), d1.blocks[0].kind.group.columns.?);
    const d1_inner = d1.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expectEqual(@as(usize, 50), d1_inner.width_pct.?);
    try testing.expectEqual(@as(usize, 0), d1.warnings.len);
    // a grid inside a skinny works too
    const d2 = try parse(arena_state.allocator(),
        \\// box skinny(80%)
        \\
        \\// g grid(2)
        \\a
        \\// --
        \\b
        \\// end g
        \\
        \\// end box
    , .empty);
    const d2_inner = d2.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expectEqual(@as(usize, 2), d2_inner.columns.?);
    try testing.expectEqual(@as(usize, 0), d2.warnings.len);
}

test "layout-level rule is per-command: a command nested under itself is stripped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // skinny in skinny: inner stripped
    const d1 = try parse(arena_state.allocator(),
        \\// box skinny(80%)
        \\
        \\// inner skinny(50%)
        \\a
        \\// end
        \\
        \\// end box
    , .empty);
    const d1_inner = d1.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expect(d1_inner.width_pct == null);
    try testing.expectEqual(@as(usize, 1), d1.warnings.len);
    try testing.expectEqualStrings(
        "group 'inner': skinny ignored (already inside a skinny)",
        d1.warnings[0],
    );
    // the counter sees any open ancestor, not just the parent:
    // skinny > grid > skinny strips the innermost skinny
    const d2 = try parse(arena_state.allocator(),
        \\// box skinny(80%)
        \\
        \\// g grid(2)
        \\
        \\// deep skinny(50%)
        \\a
        \\// end deep
        \\
        \\// --
        \\b
        \\// end g
        \\
        \\// end box
    , .empty);
    const deep = d2.blocks[0].kind.group // box
        .sections[0][0].kind.group // g
        .sections[0][0].kind.group; // deep
    try testing.expect(deep.width_pct == null);
    try testing.expectEqual(@as(usize, 1), d2.warnings.len);
    try testing.expectEqualStrings(
        "group 'deep': skinny ignored (already inside a skinny)",
        d2.warnings[0],
    );
}

test "layout-level rule: mixed opener strips only the colliding command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\// outer grid(2)
        \\
        \\// inner grid(2) skinny(50%)
        \\a
        \\// --
        \\b
        \\// end inner
        \\
        \\// --
        \\
        \\c
        \\
        \\// end outer
    , .empty);
    const inner = doc.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expect(inner.columns == null);
    try testing.expectEqual(@as(usize, 50), inner.width_pct.?);
    try testing.expectEqual(@as(usize, 1), doc.warnings.len);
    try testing.expectEqualStrings(
        "group 'inner': grid ignored (already inside a grid)",
        doc.warnings[0],
    );
}

test "layout-level rule: counters unwind when a group closes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // a grid *after* a closed grid group is a sibling, not a nesting
    const doc = try parse(arena_state.allocator(),
        \\// one grid(2)
        \\a
        \\// --
        \\b
        \\// end one
        \\
        \\// two grid(2)
        \\c
        \\// --
        \\d
        \\// end two
    , .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].kind.group.columns.?);
    try testing.expectEqual(@as(usize, 2), doc.blocks[1].kind.group.columns.?);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "layout commands inside a plain named group still apply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\// wrapper
        \\
        \\// g grid(2)
        \\a
        \\// --
        \\b
        \\// end g
        \\
        \\// end wrapper
    , .empty);
    const wrapper = doc.blocks[0].kind.group;
    try testing.expect(wrapper.columns == null);
    const inner = wrapper.sections[0][0].kind.group;
    try testing.expectEqual(@as(usize, 2), inner.columns.?);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "skinny command: on groups, with grid, and bare default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// box skinny(50%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 50), d1.blocks[0].kind.group.width_pct.?);
    const d2 = try parse(arena_state.allocator(), "// skinny()\n\npara", .empty);
    try testing.expectEqualStrings("", d2.blocks[0].kind.group.name);
    try testing.expectEqual(@as(usize, 75), d2.blocks[0].kind.group.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "// g grid(2) skinny(80%)\na\n// --\nb\n// end", .empty);
    try testing.expectEqual(@as(usize, 2), d3.blocks[0].kind.group.columns.?);
    try testing.expectEqual(@as(usize, 80), d3.blocks[0].kind.group.width_pct.?);
    try testing.expectEqual(@as(usize, 0), d3.warnings.len);
}

test "skinny command: malformed args deactivate the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{ "// g skinny(50)", "// g skinny(0%)", "// g skinny(150%)", "// g skinny(x%)" }) |src| {
        const doc = try parse(arena_state.allocator(), src, .empty);
        try testing.expect(doc.blocks[0].kind == .paragraph);
    }
}

test "center command: on groups, with other commands, and as a single command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// box center()\n\npara", .empty);
    try testing.expect(d1.blocks[0].kind.group.centered);
    const d2 = try parse(arena_state.allocator(), "// g center() skinny(50%)\n\npara", .empty);
    try testing.expect(d2.blocks[0].kind.group.centered);
    try testing.expectEqual(@as(usize, 50), d2.blocks[0].kind.group.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "/center()\n\n### heading", .empty);
    const g3 = d3.blocks[0].kind.group;
    try testing.expect(g3.centered);
    try testing.expect(g3.sections[0][0].kind == .heading);
    try testing.expectEqual(@as(usize, 0), d3.warnings.len);
}

test "center command: args deactivate the line; center-in-center is stripped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// g center(5)", .empty);
    try testing.expect(d1.blocks[0].kind == .paragraph);
    const d2 = try parse(arena_state.allocator(),
        \\// box center()
        \\
        \\// inner center()
        \\a
        \\// end
        \\
        \\// end box
    , .empty);
    const inner = d2.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expect(!inner.centered);
    try testing.expectEqual(@as(usize, 1), d2.warnings.len);
    try testing.expectEqualStrings(
        "group 'inner': center ignored (already inside a center)",
        d2.warnings[0],
    );
}

test "single command: applies to the very next content element" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "/skinny(50%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const group = doc.blocks[0].kind.group;
    try testing.expectEqualStrings("", group.name);
    try testing.expectEqual(@as(usize, 50), group.width_pct.?);
    try testing.expectEqual(@as(usize, 1), group.sections.len);
    try testing.expectEqual(@as(usize, 1), group.sections[0].len);
    try testing.expect(group.sections[0][0].kind == .paragraph);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "single command: /grid on one element applies but warns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "/grid(2)\npara", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].kind.group.columns.?);
    try testing.expectEqual(@as(usize, 1), doc.warnings.len);
    try testing.expectEqualStrings("single command: grid(2) but 1 element", doc.warnings[0]);
}

test "single command: with nothing to bind to it stays prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // EOF next
    const d1 = try parse(arena_state.allocator(), "/skinny(50%)", .empty);
    try testing.expect(d1.blocks[0].kind == .paragraph);
    // a group opener next
    const d2 = try parse(arena_state.allocator(), "/skinny(50%)\n\n// g grid(2)\na\n// --\nb\n// end", .empty);
    try testing.expectEqual(@as(usize, 2), d2.blocks.len);
    try testing.expect(d2.blocks[0].kind == .paragraph);
    try testing.expect(d2.blocks[1].kind == .group);
    // a chain that never reaches a content element (EOF at its end) reverts
    // entirely to prose — each line its own paragraph (the accepted
    // paragraph-interruption quirk), and parsing doesn't get stuck mid-chain.
    const d3 = try parse(arena_state.allocator(), "/skinny(50%)\n/color(accent)", .empty);
    try testing.expectEqual(@as(usize, 2), d3.blocks.len);
    try testing.expect(d3.blocks[0].kind == .paragraph);
    try testing.expect(d3.blocks[1].kind == .paragraph);
}

test "single command: a chain applies to the next content element" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "/skinny(50%)\n/color(accent)\npara", .empty);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const outer = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 50), outer.width_pct.?);
    try testing.expectEqual(@as(usize, 1), outer.sections.len);
    try testing.expectEqual(@as(usize, 1), outer.sections[0].len);
    const inner = outer.sections[0][0].kind.group;
    try testing.expectEqual(TextColor.accent, inner.text_color.?);
    try testing.expectEqual(@as(usize, 1), inner.sections.len);
    try testing.expectEqual(@as(usize, 1), inner.sections[0].len);
    try testing.expect(inner.sections[0][0].kind == .paragraph);

    // A repeated layout command in the chain still hits the layout-level
    // rule: the inner `skinny` is stripped and warned, exactly as it would
    // be nested two `//` groups deep.
    const d2 = try parse(arena_state.allocator(), "/skinny(50%)\n/skinny(60%)\npara", .empty);
    try testing.expectEqual(@as(usize, 1), d2.blocks.len);
    const outer2 = d2.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 50), outer2.width_pct.?);
    const inner2 = outer2.sections[0][0].kind.group;
    try testing.expect(inner2.width_pct == null);
    try testing.expect(std.mem.indexOf(u8, d2.warnings[0], "skinny ignored") != null);
}

test "single command: prose slash lines stay prose and never interrupt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "/usr/bin/env foo", .empty);
    try testing.expect(d1.blocks[0].kind == .paragraph);
    // a prose slash line keeps soft-wrapping into the open paragraph
    const d2 = try parse(arena_state.allocator(), "text\n/usr/bin/env", .empty);
    try testing.expectEqual(@as(usize, 1), d2.blocks.len);
    // a clean command line does interrupt
    const d3 = try parse(arena_state.allocator(), "text\n/skinny(50%)\npara", .empty);
    try testing.expectEqual(@as(usize, 2), d3.blocks.len);
    try testing.expect(d3.blocks[0].kind == .paragraph);
    try testing.expect(d3.blocks[1].kind == .group);
}

test "single command inside a grid group: a different command still applies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// g grid(2)\n/skinny(50%)\na\n// --\nb\n// end", .empty);
    const outer = doc.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 2), outer.sections.len);
    const wrapped = outer.sections[0][0].kind.group;
    try testing.expectEqual(@as(usize, 50), wrapped.width_pct.?);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "single command inside a laid-out group: the same command is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// box skinny(80%)\n/skinny(50%)\na\n// end", .empty);
    const wrapped = doc.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expect(wrapped.width_pct == null);
    try testing.expectEqual(@as(usize, 1), doc.warnings.len);
    try testing.expectEqualStrings(
        "single command: skinny ignored (already inside a skinny)",
        doc.warnings[0],
    );
}

test "group directive: unclean // lines stay prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // unknown bare words after the name deactivate the whole line
    const doc = try parse(arena_state.allocator(), "// just a comment", .empty);
    try testing.expect(doc.blocks[0].kind == .paragraph);
    // unknown command, malformed args, //-glued word, reserved name
    for ([_][]const u8{ "// box glow(5)", "// g grid(zero)", "// g grid(0)", "//foo", "// -- grid(2)" }) |src| {
        const d = try parse(arena_state.allocator(), src, .empty);
        try testing.expect(d.blocks[0].kind == .paragraph);
    }
}

test "group directive: separator and closer outside a group stay prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// --\n\n// end\n\n//", .empty);
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    for (doc.blocks) |b| try testing.expect(b.kind == .paragraph);
}

test "group directive: grid section-count mismatch warns but renders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// g grid(2)\na\n// --\nb\n// --\nc\n// end", .empty);
    const group = doc.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 3), group.sections.len);
    try testing.expectEqual(@as(usize, 1), doc.warnings.len);
    try testing.expectEqualStrings("group 'g': grid(2) but 3 section(s)", doc.warnings[0]);
}

test "group opener interrupts a paragraph; inert // lines soft-wrap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "text\n// g grid(2)\na\n// end", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expect(doc.blocks[0].kind == .paragraph);
    try testing.expect(doc.blocks[1].kind == .group);
    // an inert // line keeps joining the paragraph, as in plain markdown
    const d2 = try parse(arena_state.allocator(), "text\n// just prose", .empty);
    try testing.expectEqual(@as(usize, 1), d2.blocks.len);
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

test "color command: on groups, with other commands, and as a single command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// note color(muted)\n\npara", .empty);
    try testing.expectEqual(TextColor.muted, d1.blocks[0].kind.group.text_color.?);
    const d2 = try parse(arena_state.allocator(), "// g color(accent) skinny(50%)\n\npara", .empty);
    try testing.expectEqual(TextColor.accent, d2.blocks[0].kind.group.text_color.?);
    try testing.expectEqual(@as(usize, 50), d2.blocks[0].kind.group.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "/color(fg)\n\n### heading", .empty);
    const g3 = d3.blocks[0].kind.group;
    try testing.expectEqual(TextColor.fg, g3.text_color.?);
    try testing.expect(g3.sections[0][0].kind == .heading);
    try testing.expectEqual(@as(usize, 0), d3.warnings.len);
}

test "color command: unknown roles and malformed args deactivate the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{ "// g color(red)", "// g color()", "// g color(#fff)", "/color(bright)" }) |src| {
        const doc = try parse(arena_state.allocator(), src, .empty);
        try testing.expect(doc.blocks[0].kind == .paragraph);
    }
}

test "color command is non-layout: color-in-color nests without stripping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\// box color(muted)
        \\
        \\// inner color(accent)
        \\a
        \\// end
        \\
        \\// end box
    , .empty);
    try testing.expectEqual(TextColor.muted, doc.blocks[0].kind.group.text_color.?);
    const inner = doc.blocks[0].kind.group.sections[0][0].kind.group;
    try testing.expectEqual(TextColor.accent, inner.text_color.?);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "color span: [text].color(role) parses with nested inlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "a [**big** word].color(accent) b", .empty);
    const inls = doc.blocks[0].kind.paragraph;
    try testing.expectEqual(@as(usize, 3), inls.len);
    const span = inls[1].color_span;
    try testing.expectEqual(TextColor.accent, span.color);
    try testing.expect(span.children[0] == .strong);
    try testing.expectEqualStrings(" word", span.children[1].text);
}

test "color span: restricted forms stay literal prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // a link wins its `[` — no postfix-on-link
    const d1 = try parse(arena_state.allocator(), "[label](url).color(accent)", .empty);
    const p1 = d1.blocks[0].kind.paragraph;
    try testing.expect(p1[0] == .link);
    try testing.expectEqualStrings(".color(accent)", p1[1].text);
    // unknown role, escaped bracket, unterminated args: all literal
    const d2 = try parse(arena_state.allocator(), "[x].color(red)", .empty);
    try testing.expect(d2.blocks[0].kind.paragraph[0] == .text);
    const d3 = try parse(arena_state.allocator(), "\\[x].color(accent)", .empty);
    try testing.expect(d3.blocks[0].kind.paragraph[0] == .text);
    const d4 = try parse(arena_state.allocator(), "[x].color(accent", .empty);
    try testing.expect(d4.blocks[0].kind.paragraph[0] == .text);
    // no nesting: brackets don't pair — the earliest `].color(` closes the
    // span (exactly parseLink's non-nesting scan), the rest stays literal
    const d5 = try parse(arena_state.allocator(), "[a [b].color(muted) c].color(accent)", .empty);
    const p5 = d5.blocks[0].kind.paragraph;
    try testing.expectEqual(TextColor.muted, p5[0].color_span.color);
    try testing.expectEqualStrings("a [b", p5[0].color_span.children[0].text);
    try testing.expectEqualStrings(" c].color(accent)", p5[1].text);
}
