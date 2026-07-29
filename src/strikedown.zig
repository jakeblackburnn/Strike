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
//!   - paragraphs (soft-wrapped lines are joined with a space); leading
//!     whitespace on a paragraph's first line indents it one step
//!     (`docs/reference/design/015-paragraph-indent.md`) — paragraphs only, and the
//!     amount of whitespace is deliberately not significant
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
//!     `docs/reference/design/001-groups.md`); a `//` line is a directive **iff it
//!     parses cleanly**, otherwise prose
//!   - single-command directives (`/skinny(60%)`) applying one command to the
//!     very next content element (see `docs/reference/design/002-single-command.md`)
//!
//! Inline grammar, in precedence order: backslash escape, `` `code` ``,
//! `$math$`, `![alt](src)`, `[text](url)`, `[text].color(role)` color spans
//! (see `docs/reference/design/006-color.md`), `<http…>` and bare-URL autolinks,
//! `***`/`**`/`*` emphasis, `~~strikethrough~~`. Emphasis delimiters and
//! inline-math `$` obey flanking/adjacency rules so prose asterisks and
//! dollars stay literal (`docs/reference/design/014-flanking.md`). Code/math bodies
//! are never inline-parsed.
//!
//! Layout and typography land as *data on tree nodes* — command-derived
//! attributes in `Block.attrs` (e.g. `columns`, `text_color`) — never as
//! emitter special cases. A group whose attrs carry a layout command is a
//! *layout element*; one carrying only non-layout commands (`color`) is a
//! *styled container*; one with no commands is a plain container
//! (`docs/reference/MODEL.md` maps the full taxonomy to these types). Every superset
//! form must degrade to inert prose in plain markdown documents that never
//! activate it.

const std = @import("std");
const sheet = @import("sheet.zig");
const Allocator = std.mem.Allocator;

// ---- document model ----------------------------------------------------------

pub const Doc = struct {
    blocks: []Block,
    /// Parse-time diagnostics (e.g. a `grid(n)` section-count mismatch):
    /// flat human-readable arena strings in discovery order, deliberately
    /// unstructured — callers print them, nothing branches on them (grow a
    /// typed field only when a structured consumer exists). `parse` stays
    /// pure — callers decide whether to print.
    warnings: []const []const u8 = &.{},
};

/// One block-level element — a *content element*, or a group arranging
/// content elements. Shared command-derived attributes live in `attrs`
/// beside the structural payload in `kind`, so every block type gets them
/// uniformly; today only group blocks carry non-default attrs.
pub const Block = struct {
    kind: Kind,
    attrs: Attrs = .{},

    pub const Kind = union(enum) {
        heading: Heading,
        paragraph: []Inline,
        quote: Quote,
        list: List,
        code: Code,
        table: Table,
        /// Raw display-math TeX (multi-line joined with '\n'), not escaped.
        math: []const u8,
        rule,
        group: Group,
    };
};

/// Command-derived presentation attributes. Commands write these fields
/// (`applyCommand`), emitters read them through one shared style helper —
/// data all the way, never emitter special cases. Today group blocks
/// (including `/cmd()` desugarings) carry non-default attrs, plus any
/// paragraph whose first line is whitespace-indented (note 015); future
/// element-type-specific commands (`// ###.color(accent)`) will write these
/// same fields onto heading/paragraph/… blocks with no further model change.
pub const Attrs = struct {
    columns: ?usize = null, // from grid(n) (layout)
    width_pct: ?usize = null, // from skinny(N%) or wide(N%): % of the body column
    // width (layout). One field, two commands: ≤ 100 was written by skinny,
    // > 100 by wide — the grammar keeps the ranges disjoint (see `Command.wide`)
    centered: bool = false, // from center(): center-align contained text (layout)
    text_color: ?TextColor = null, // from color(role): theme text color (non-layout)
    collapse: ?Collapse = null, // from collapse(): fold behind the leader (layout, structural)
    indent: usize = 0, // from indent(n), or one step from a whitespace-indented
    // paragraph (note 015): first-line indent steps,
    // rendered as CSS text-indent — affects a block's own first line only, and on a
    // group cascades to each child via CSS inheritance (non-layout)

    /// True when any command set a field. Runs over the exhaustive
    /// `hasCommand` switch, so a new command can never be forgotten here.
    pub fn any(a: Attrs) bool {
        for (std.meta.tags(CommandTag)) |t| {
            if (hasCommand(a, t)) return true;
        }
        return false;
    }

    /// True when any *styling* command set a field — the emitter's "does
    /// this block need a style attribute" check. Structural commands
    /// (`collapse`) shape the emitted elements instead and never produce
    /// style declarations.
    pub fn anyStyle(a: Attrs) bool {
        for (std.meta.tags(CommandTag)) |t| {
            if (!isStructural(t) and hasCommand(a, t)) return true;
        }
        return false;
    }
};

/// A group's structural payload: named sections of content. The group's
/// commands land on its `Block.attrs` (data, not emitter special cases) —
/// a group whose attrs carry a layout command *is* a layout element; one
/// carrying only `color` is a styled container; one with no commands is a
/// plain container. A single-command directive (`/cmd()`) produces this
/// same node: nameless, one section holding the one element it binds to.
pub const Group = struct {
    name: []const u8, // "" = nameless (runs to EOF unless closed)
    sections: [][]Block,
};

/// A theme color role (`docs/reference/design/006-color.md`). Strikedown never names
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

/// A collapsible group's initial state (`docs/reference/design/007-collapse.md`).
/// `collapse()` folds the group closed behind its leader; `collapse(open)`
/// starts it open. State is per page load — nothing persists.
pub const Collapse = enum { closed, open };

pub const Heading = struct {
    level: usize, // 1..6
    id: []const u8, // slugified anchor, deduped per document
    inlines: []Inline,
};

/// A blockquote, optionally typed as an alert (`docs/reference/design/009-alerts.md`).
pub const Quote = struct {
    /// Set when the quote's first content is an `[!TYPE]` marker; unknown
    /// types leave the quote plain (the marker stays literal text).
    alert: ?Alert = null,
    /// The quote's paragraphs: consecutive `>` lines merge into one,
    /// a bare `>` line separates them.
    paras: [][]Inline,
};

/// An alert type: the GFM five plus the strike extras. Matched
/// case-insensitively; renderers title the quote with it.
pub const Alert = enum { note, tip, important, warning, caution, todo, example, question };

pub const Code = struct {
    lang: []const u8, // "" if the fence had no info string
    text: []const u8, // verbatim body, every line '\n'-terminated
};

pub const List = struct {
    ordered: bool,
    /// A raw list (`. ` items, `docs/reference/design/008-raw-lists.md`): unordered,
    /// rendered with no item marker. Marker kinds don't mix at one level.
    plain: bool = false,
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
    /// `[text].color(role)` — a colored span (`docs/reference/design/006-color.md`).
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
    /// The document's lines, raw (untrimmed) — block parsers trim as they
    /// classify, and the paragraph arm reads the raw form to see a leading
    /// whitespace indent (note 015).
    lines: [][]const u8,
    idx: usize = 0,
    /// Heading anchor slugs used so far in this document (for deduping).
    used_slugs: std.ArrayList([]const u8) = .empty,
    /// How many groups are open. Separator/closer group lines are only live
    /// inside a group; outside they stay prose (`isGroupInterrupt`).
    group_depth: usize = 0,
    /// How many open groups carry each layout command. The layout-level rule
    /// is per-command (`docs/reference/STRIKEDOWN.md`): a layout command whose counter
    /// is already > 0 — an open ancestor carries the same command — is
    /// ignored with a warning; other commands on the same opener still apply.
    layout_depth: std.enums.EnumArray(CommandTag, usize) = .initFill(0),
    /// Diagnostics collected while parsing (handed to `Doc.warnings`).
    warnings: std.ArrayList([]const u8) = .empty,

    /// Parse the block starting at `idx` (which is non-blank), advancing past
    /// it. Returns null for lines consumed without producing a block
    /// (typography directives).
    fn next(p: *Parser) Allocator.Error!?Block {
        const t = trimIndent(p.lines[p.idx]);

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
                !std.mem.startsWith(u8, trimIndent(p.lines[p.idx]), "```"))
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
            var alert: ?Alert = null;
            var seen_content = false;
            var paras: std.ArrayList([]Inline) = .empty;
            var cur: std.ArrayList(u8) = .empty;
            while (p.idx < p.lines.len) {
                if (isBlank(p.lines[p.idx])) break;
                const qt = trimIndent(p.lines[p.idx]);
                if (std.mem.startsWith(u8, qt, ">")) {
                    var content = qt[1..];
                    if (content.len > 0 and content[0] == ' ') content = content[1..];
                    content = std.mem.trimEnd(u8, content, " \t");
                    if (content.len == 0) {
                        // Bare `>`: paragraph break within the quote.
                        if (cur.items.len > 0) {
                            try paras.append(arena, try parseFlowRun(arena, cur.items));
                            cur.clearRetainingCapacity();
                        }
                    } else {
                        // The quote's very first content may be an alert
                        // marker; trailing same-line text starts paragraph 1.
                        if (!seen_content) {
                            seen_content = true;
                            if (parseAlertMarker(content)) |m| {
                                alert = m.alert;
                                content = m.rest;
                                if (content.len == 0) {
                                    p.idx += 1;
                                    continue;
                                }
                            }
                        }
                        try appendFlowLine(arena, &cur, content);
                    }
                    p.idx += 1;
                    continue;
                }
                // Lazy continuation needs an open paragraph and a line that
                // starts no block.
                if (cur.items.len == 0) break;
                if (p.interruptsFlow(qt)) break;
                try appendFlowLine(arena, &cur, qt);
                p.idx += 1;
            }
            if (cur.items.len > 0) try paras.append(arena, try parseFlowRun(arena, cur.items));
            return .{ .kind = .{ .quote = .{ .alert = alert, .paras = try paras.toOwnedSlice(arena) } } };
        }

        // List (unordered or ordered, possibly nested by indentation).
        if (parseMarker(t) != null) {
            return .{ .kind = .{ .list = try p.parseList() } };
        }

        // GFM pipe table: a header row followed by a `|---|` separator row.
        if (isTableStart(p.lines, p.idx)) {
            var header_cells: std.ArrayList([]const u8) = .empty;
            try splitCells(arena, &header_cells, trimIndent(p.lines[p.idx]));
            var aligns: std.ArrayList(Align) = .empty;
            try parseAligns(arena, &aligns, trimIndent(p.lines[p.idx + 1]));
            p.idx += 2;

            var header: std.ArrayList([]Inline) = .empty;
            for (header_cells.items) |cell| try header.append(arena, try parseInlines(arena, cell));

            var rows: std.ArrayList([][]Inline) = .empty;
            var row_cells: std.ArrayList([]const u8) = .empty;
            while (p.idx < p.lines.len) {
                const rt = trimIndent(p.lines[p.idx]);
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
        // Leading whitespace on the paragraph's *first* line indents it one
        // step (015-paragraph-indent) — the raw line is read before trimming,
        // and only here, which is what confines the rule to paragraphs.
        // Continuation lines soft-wrap regardless of their own indentation.
        const indented = hasParagraphIndent(p.lines[p.idx]);
        var flow: std.ArrayList(u8) = .empty;
        try appendFlowLine(arena, &flow, std.mem.trimEnd(u8, t, " \t"));
        p.idx += 1;
        while (p.idx < p.lines.len and !isBlank(p.lines[p.idx])) {
            const nt = std.mem.trim(u8, p.lines[p.idx], " \t");
            if (p.interruptsFlow(nt)) break;
            try appendFlowLine(arena, &flow, nt);
            p.idx += 1;
        }
        return .{
            .kind = .{ .paragraph = try parseInlines(arena, flow.items) },
            .attrs = .{ .indent = if (indented) 1 else 0 },
        };
    }

    /// Parse one (possibly nested) list starting at `idx`, advancing past the
    /// consumed lines. Nesting is by indentation: an item indented >= 2 columns
    /// past its parent opens a child list inside the parent's item; a dedent
    /// returns to the outer level; a marker of another kind (ordered vs
    /// unordered vs raw) at the same level ends this list (the block loop
    /// starts the sibling). A
    /// non-marker line that starts no block soft-wraps into the open item,
    /// indented or not (lazy continuation, as in quotes). Blank lines end the
    /// list unless the next non-blank line is a marker continuing it — a
    /// sibling of the same orderedness, or a nested item; rendering stays
    /// tight either way (`<p>`-wrapped loose rendering is out of scope).
    fn parseList(p: *Parser) Allocator.Error!List {
        const arena = p.arena;
        const base = indentWidth(p.lines[p.idx]);
        const first = parseMarker(trimIndent(p.lines[p.idx])) orelse unreachable;
        const ordered = first.ordered;
        const plain = first.plain;
        var items: std.ArrayList(Item) = .empty;
        var tail: std.ArrayList(Item.Tail) = .empty;
        // Raw text of the open soft-wrap run (an item's own line and the lines
        // lazily continuing it); parsed as one string by `flushFlow`.
        var flow: std.ArrayList(u8) = .empty;
        while (p.idx < p.lines.len) {
            const line = p.lines[p.idx];
            if (isBlank(line)) {
                // Skip the blank run iff a marker that continues this list
                // follows; only a marker resumes a list across a blank.
                var j = p.idx;
                while (j < p.lines.len and isBlank(p.lines[j])) j += 1;
                if (j == p.lines.len) break;
                const m = parseMarker(trimIndent(p.lines[j])) orelse break;
                const nind = indentWidth(p.lines[j]);
                if (nind < base) break;
                if (nind < base + 2 and (m.ordered != ordered or m.plain != plain)) break;
                p.idx = j;
                continue;
            }
            const ind = indentWidth(line);
            const t = trimIndent(line);
            if (parseMarker(t)) |m| {
                if (ind >= base + 2) {
                    if (items.items.len == 0) break;
                    try flushFlow(arena, &flow, &items, &tail);
                    try tail.append(arena, .{ .list = try p.parseList() });
                    continue;
                }
                if (ind < base or m.ordered != ordered or m.plain != plain) break;
                try flushFlow(arena, &flow, &items, &tail);
                if (items.items.len > 0)
                    items.items[items.items.len - 1].tail = try tail.toOwnedSlice(arena);
                try items.append(arena, .{ .task = m.task, .text = &.{} });
                try appendFlowLine(arena, &flow, std.mem.trimEnd(u8, t[m.content_start..], " \t"));
                p.idx += 1;
                continue;
            }
            // Non-marker line: one that starts no block continues the open
            // item; anything else ends the list (the block loop decides what
            // it is).
            if (items.items.len > 0 and !p.interruptsFlow(t)) {
                try appendFlowLine(arena, &flow, std.mem.trimEnd(u8, t, " \t"));
                p.idx += 1;
                continue;
            }
            break;
        }
        try flushFlow(arena, &flow, &items, &tail);
        if (items.items.len > 0)
            items.items[items.items.len - 1].tail = try tail.toOwnedSlice(arena);
        return .{ .ordered = ordered, .plain = plain, .start = first.num, .items = try items.toOwnedSlice(arena) };
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
        var attrs = open.attrs;
        try p.stripNestedLayout(&attrs, open.name);
        p.enterLayout(attrs);
        defer p.exitLayout(attrs);
        var sections: std.ArrayList([]Block) = .empty;
        var cur: std.ArrayList(Block) = .empty;
        while (p.idx < p.lines.len) {
            if (isBlank(p.lines[p.idx])) {
                p.idx += 1;
                continue;
            }
            const t = trimIndent(p.lines[p.idx]);
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
                .end => |name| if (name == null or std.mem.eql(u8, name.?, open.name)) {
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
                .{ groupLabel(open.name), n, sections.items.len },
            ));
        };
        return .{
            .kind = .{ .group = .{
                .name = open.name,
                .sections = try sections.toOwnedSlice(arena),
            } },
            .attrs = attrs,
        };
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
        const nt = trimIndent(p.lines[j]);
        if (p.isGroupInterrupt(nt) or sheet.parseLine(nt) != null) return null;

        var attrs: Attrs = .{};
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
        return .{
            .kind = .{ .group = .{ .name = "", .sections = sections } },
            .attrs = attrs,
        };
    }

    /// The layout-level rule, per command (`docs/reference/STRIKEDOWN.md`): clear
    /// each layout command in `attrs` that an open ancestor already carries,
    /// warning per stripped command. `name` is the group's name for the
    /// warning (null for a single-command directive). Commands that don't
    /// collide survive — the rule strips commands, never openers.
    fn stripNestedLayout(p: *Parser, attrs: *Attrs, name: ?[]const u8) Allocator.Error!void {
        for (std.meta.tags(CommandTag)) |tag| {
            if (!isLayout(tag)) continue;
            if (hasCommand(attrs.*, tag) and p.layout_depth.get(tag) > 0) {
                clearCommand(attrs, tag);
                try p.warnStrippedLayout(name, @tagName(tag));
            }
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
    /// attrs. Non-layout commands never touch a counter (`isLayout`).
    fn enterLayout(p: *Parser, attrs: Attrs) void {
        for (std.meta.tags(CommandTag)) |tag| {
            if (isLayout(tag) and hasCommand(attrs, tag)) p.layout_depth.getPtr(tag).* += 1;
        }
    }

    fn exitLayout(p: *Parser, attrs: Attrs) void {
        for (std.meta.tags(CommandTag)) |tag| {
            if (isLayout(tag) and hasCommand(attrs, tag)) p.layout_depth.getPtr(tag).* -= 1;
        }
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

/// Turn heading text into an anchor slug: lowercased, `a-z0-9` and non-ASCII
/// text kept, every other run of characters collapsed to a single `-`, no
/// leading/trailing `-`. Falls back to `"section"` when nothing survives.
/// Exported for future TOC/copy-link features. Caller owns the result.
pub fn slugify(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_dash = false;
    for (text) |c| {
        // Non-ASCII bytes survive verbatim. Every byte of a UTF-8 sequence is
        // >= 0x80, so multi-byte characters come through whole rather than
        // collapsing to a dash — without this, `# 中文` slugs to nothing and
        // falls back to "section", colliding with every other non-Latin
        // heading in the document. Case is left alone here (folding `É` needs
        // Unicode tables this project doesn't carry), so a mixed heading can
        // slug to mixed case; ids are exact strings, so that's cosmetic.
        if (c >= 0x80) {
            if (pending_dash and out.items.len > 0) try out.append(gpa, '-');
            pending_dash = false;
            try out.append(gpa, c);
            continue;
        }
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

/// Append one soft-wrapped line to a flow buffer, space-joined to whatever is
/// already there. Every flowing-text block (paragraph, quote paragraph, list
/// item) gathers its lines this way and inline-parses the buffer *once*, when
/// the run ends: inline syntax is a property of the joined text, so a span may
/// open on one line and close on a later one (`*asdf\nasdf*` is one emphasis,
/// not two literal asterisks).
fn appendFlowLine(arena: Allocator, buf: *std.ArrayList(u8), line: []const u8) Allocator.Error!void {
    if (line.len == 0) return;
    if (buf.items.len > 0) try buf.append(arena, ' ');
    try buf.appendSlice(arena, line);
}

/// Inline-parse the contents of a *reused* flow buffer (list items, quote
/// paragraphs — the ones `clearRetainingCapacity` refills for the next run).
///
/// Inline nodes carry slices *into* their input rather than copies —
/// `.code`, `.math`, `.link.url`, `.autolink`, image src/alt — so parsing
/// straight from the buffer would leave every one of them pointing at memory
/// the next run overwrites (a list of links rendered as binary garbage).
/// Duping the joined text into the arena first gives those slices stable
/// memory for the document's lifetime. `.text` nodes were always safe: they
/// are built up in their own buffer and handed over with `toOwnedSlice`.
fn parseFlowRun(arena: Allocator, buf: []const u8) Allocator.Error![]Inline {
    return parseInlines(arena, try arena.dupe(u8, buf));
}

/// End a list item's soft-wrap run: inline-parse the gathered text into the
/// open item's own content, or — when a nested list has already interrupted
/// the item — into a trailing `.line` segment.
fn flushFlow(
    arena: Allocator,
    flow: *std.ArrayList(u8),
    items: *std.ArrayList(Item),
    tail: *std.ArrayList(Item.Tail),
) Allocator.Error!void {
    if (flow.items.len == 0 or items.items.len == 0) return;
    const inls = try parseFlowRun(arena, flow.items);
    flow.clearRetainingCapacity();
    if (tail.items.len == 0) {
        items.items[items.items.len - 1].text = inls;
    } else {
        try tail.append(arena, .{ .line = inls });
    }
}

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
/// (`docs/reference/design/002-single-command.md`) that keeps this check context-free.
fn isBlockStart(t: []const u8) bool {
    return headingLevel(t) != null or
        isHorizontalRule(t) or
        std.mem.startsWith(u8, t, ">") or
        std.mem.startsWith(u8, t, "```") or
        std.mem.startsWith(u8, t, "$$") or
        isUnorderedItem(t) or
        isPlainItem(t) or
        orderedMarker(t) != null or
        parseSingleCommandLine(t) != null or
        sheet.parseLine(t) != null;
}

/// Strip a line's leading whitespace. Spaces and tabs are the same thing to
/// every block classifier — indentation is insignificant to *what* a line is
/// (note 015 gives it meaning in exactly one place: `hasParagraphIndent`).
fn trimIndent(line: []const u8) []const u8 {
    return std.mem.trimStart(u8, line, " \t");
}

/// Does a paragraph starting at this raw (untrimmed) line carry the one-step
/// whitespace indent (`docs/reference/design/015-paragraph-indent.md`)? Any leading
/// whitespace — one space, four, or a tab — means one step; the amount and
/// kind are deliberately not significant. Only paragraphs consult this: every
/// other block form is classified from the trimmed line and ignores leading
/// whitespace exactly as before.
fn hasParagraphIndent(raw_line: []const u8) bool {
    return raw_line.len > 0 and (raw_line[0] == ' ' or raw_line[0] == '\t');
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

/// Match an alert marker `[!type]` (case-insensitive) at the start of a
/// quote's first content line. `rest` is the text after the marker (same-line
/// body; empty when the marker stands alone). The marker must be followed by
/// a space or end-of-line, and an unknown type is no marker at all — the
/// quote stays plain and the text literal (`docs/reference/design/009-alerts.md`).
fn parseAlertMarker(content: []const u8) ?struct { alert: Alert, rest: []const u8 } {
    if (!std.mem.startsWith(u8, content, "[!")) return null;
    const close = std.mem.indexOfScalar(u8, content, ']') orelse return null;
    const name = content[2..close];
    var buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    const alert = std.meta.stringToEnum(Alert, std.ascii.lowerString(&buf, name)) orelse return null;
    const after = content[close + 1 ..];
    if (after.len > 0 and after[0] != ' ') return null;
    return .{ .alert = alert, .rest = std.mem.trimStart(u8, after, " ") };
}

fn isUnorderedItem(t: []const u8) bool {
    return t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ';
}

/// A raw-list item marker: `. ` (`docs/reference/design/008-raw-lists.md`).
fn isPlainItem(t: []const u8) bool {
    return t.len >= 2 and t[0] == '.' and t[1] == ' ';
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
    /// The raw-list marker `. ` — unordered, rendered markerless.
    plain: bool,
    /// Offset of the item text within the trimmed line (past marker + task box).
    content_start: usize,
    /// The written number (`12. ` -> 12); 1 for unordered markers.
    num: usize,
    /// null = plain item; true/false = checked/unchecked task box.
    task: ?bool,
};

/// Parse a list-item marker (`- `, `* `, `+ `, `. `, `12. `) at the start of
/// a left-trimmed line, plus an optional `[ ]`/`[x]` task box after it.
fn parseMarker(t: []const u8) ?Marker {
    var m: Marker = undefined;
    if (isUnorderedItem(t)) {
        m = .{ .ordered = false, .plain = false, .content_start = 2, .num = 1, .task = null };
    } else if (isPlainItem(t)) {
        m = .{ .ordered = false, .plain = true, .content_start = 2, .num = 1, .task = null };
    } else if (orderedMarker(t)) |om| {
        m = .{ .ordered = true, .plain = false, .content_start = om.len, .num = om.num, .task = null };
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

/// One classified group-directive line (`docs/reference/design/001-groups.md`).
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
        name: []const u8 = "", // "" = nameless
        attrs: Attrs = .{},
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

    var open: GroupLine.Open = .{};
    if (parseCommand(first)) |cmd| {
        applyCommand(&open.attrs, cmd);
    } else {
        if (!sheet.isAliasName(first) or std.mem.eql(u8, first, "--")) return null;
        open.name = first;
    }
    while (it.next()) |tok| {
        applyCommand(&open.attrs, parseCommand(tok) orelse return null);
    }
    return .{ .open = open };
}

/// The recognized commands. A new command is a variant here, a
/// `parseCommand` arm, an `Attrs` field written by an `applyCommand` arm,
/// its `isLayout`/`isStructural`/`hasCommand`/`clearCommand` arms
/// (exhaustive switches — the compiler finds them for you), and the emitter
/// reading the field (the style helper for styling commands, the element
/// shape for structural ones) — data all the way, per the extension recipe. The depth
/// machinery, `//`-opener and `/cmd()` support, and `Attrs.any` come free.
/// A *layout* command creates a layout element, and its tag keys a
/// `Parser.layout_depth` counter for the per-command layout-level rule
/// (`stripNestedLayout`/`enterLayout`); a non-layout command (`color`)
/// simply never touches a counter, so it nests freely.
const Command = union(enum) {
    grid: usize,
    /// skinny(N%): render at N% of the body column width, centered.
    /// Writes `width_pct` — see `wide` for the shared-field invariant.
    skinny: usize,
    /// wide(N%): render at N% of the body column width, centered — the
    /// mirror of `skinny`, bleeding evenly into both margins. Both commands
    /// write the one `Attrs.width_pct` field and the grammar keeps their
    /// ranges disjoint: a value ≤ 100 was written by `skinny`, > 100 by
    /// `wide`. That invariant is what `hasCommand`/`clearCommand` read.
    wide: usize,
    /// center(): center-align text within the surrounding layout element.
    center,
    /// color(role): set the contained text's theme color. Non-layout —
    /// nested colors are meaningful (inner wins by cascade).
    color: TextColor,
    /// collapse(): fold the group behind its leader, closed by default;
    /// collapse(open) starts open. Layout and *structural* — it shapes the
    /// emitted elements rather than adding style declarations.
    collapse: Collapse,
    /// indent(n): a first-line typographic tab indent, n steps; a
    /// whitespace-indented paragraph writes one step of the same data
    /// (011-indent, 015-paragraph-indent).
    /// Non-layout — nesting scopes, it doesn't stack: an inner indent(n)
    /// overrides the inherited value for its own subtree (plain CSS
    /// text-indent semantics), the same as color's inner-wins cascade.
    indent: usize,
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
    if (std.mem.eql(u8, word, "wide")) {
        if (args.len == 0) return .{ .wide = 125 }; // bare wide(): the default width
        if (args[args.len - 1] != '%') return null;
        const n = std.fmt.parseInt(usize, args[0 .. args.len - 1], 10) catch return null;
        if (n <= 100 or n > 200) return null; // 100% and below is skinny's range
        return .{ .wide = n };
    }
    if (std.mem.eql(u8, word, "center")) {
        if (args.len != 0) return null; // center() takes no arguments
        return .center;
    }
    if (std.mem.eql(u8, word, "color")) {
        const role = TextColor.parse(args) orelse return null;
        return .{ .color = role };
    }
    if (std.mem.eql(u8, word, "collapse")) {
        if (args.len == 0) return .{ .collapse = .closed }; // collapse(): closed by default
        if (std.mem.eql(u8, args, "open")) return .{ .collapse = .open };
        return null;
    }
    if (std.mem.eql(u8, word, "indent")) {
        if (args.len == 0) return .{ .indent = 1 }; // bare indent(): one step
        const n = std.fmt.parseInt(usize, args, 10) catch return null;
        if (n == 0) return null;
        return .{ .indent = n };
    }
    return null;
}

fn applyCommand(attrs: *Attrs, cmd: Command) void {
    switch (cmd) {
        .grid => |n| attrs.columns = n,
        .skinny, .wide => |n| attrs.width_pct = n,
        .center => attrs.centered = true,
        .color => |role| attrs.text_color = role,
        .collapse => |c| attrs.collapse = c,
        .indent => |n| attrs.indent = n,
    }
}

const CommandTag = std.meta.Tag(Command);

/// Layout commands create layout elements and count under the per-command
/// layout-level rule; non-layout commands (`color`) style without creating
/// one and nest freely. Exhaustive: a new `Command` variant is a compile
/// error here until classified.
fn isLayout(tag: CommandTag) bool {
    return switch (tag) {
        .grid, .skinny, .wide, .center, .collapse => true,
        .color, .indent => false,
    };
}

/// Structural commands are expressed by the emitter's *element* choice
/// (collapse -> a disclosure element), never as style declarations —
/// `Attrs.anyStyle` skips them so they don't produce empty style attributes.
/// Exhaustive, like `isLayout`.
fn isStructural(tag: CommandTag) bool {
    return switch (tag) {
        .collapse => true,
        .grid, .skinny, .wide, .center, .color, .indent => false,
    };
}

/// Does `attrs` carry `tag`'s command — is the field it writes set?
fn hasCommand(attrs: Attrs, tag: CommandTag) bool {
    return switch (tag) {
        .grid => attrs.columns != null,
        // The disjoint-range invariant (see `Command.wide`): one field, and
        // which side of 100 the value sits on names the command that wrote it.
        .skinny => attrs.width_pct != null and attrs.width_pct.? <= 100,
        .wide => attrs.width_pct != null and attrs.width_pct.? > 100,
        .center => attrs.centered,
        .color => attrs.text_color != null,
        .collapse => attrs.collapse != null,
        .indent => attrs.indent != 0,
    };
}

/// Unset the field `tag`'s command writes (the layout-level rule strips
/// colliding commands with this).
fn clearCommand(attrs: *Attrs, tag: CommandTag) void {
    switch (tag) {
        .grid => attrs.columns = null,
        // Each clears the shared width field only when the value is on its
        // own side of 100 (the disjoint-range invariant).
        .skinny, .wide => if (hasCommand(attrs.*, tag)) {
            attrs.width_pct = null;
        },
        .center => attrs.centered = false,
        .color => attrs.text_color = null,
        .collapse => attrs.collapse = null,
        .indent => attrs.indent = 0,
    }
}

fn groupLabel(name: []const u8) []const u8 {
    return if (name.len > 0) name else "(nameless)";
}

/// Classify a (left-trimmed) line as a single-command directive
/// (`docs/reference/design/002-single-command.md`): `/` immediately followed by exactly
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
    const t = trimIndent(lines[idx]);
    if (isBlockStart(t) or std.mem.indexOfScalar(u8, t, '|') == null) return false;
    return isTableSeparator(trimIndent(lines[idx + 1]));
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

/// Strip at most one leading and one trailing boundary pipe. Separator rows
/// only — they can hold nothing but `-`, `:`, `|` and spaces, so there are no
/// escapes to worry about here; `splitCells` handles its own boundaries.
fn stripBoundaryPipes(s: []const u8) []const u8 {
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
fn splitCells(gpa: Allocator, cells: *std.ArrayList([]const u8), row: []const u8) Allocator.Error!void {
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
/// (`docs/reference/design/006-color.md`). Same first-`]` scan as `parseLink` — which
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
    // The continuation joins the item's own flow (one inline run), so nothing
    // lands in the tail — `.line` segments only appear after a nested list.
    try testing.expectEqual(@as(usize, 0), list.items[0].tail.len);
    try testing.expectEqualStrings("a wraps", list.items[0].text[0].text);
}

test "list: emphasis opened on an item line closes on its continuation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- *a\n  wraps*", .empty);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 1), list.items[0].text.len);
    try testing.expect(list.items[0].text[0] == .em);
    try testing.expectEqualStrings("a wraps", list.items[0].text[0].em[0].text);
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

test "raw list: . items parse as one plain unordered list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), ". one\n. two\n. three", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const list = doc.blocks[0].kind.list;
    try testing.expect(list.plain);
    try testing.expect(!list.ordered);
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "raw list: marker kinds don't mix at one level" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- bulleted\n. raw", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expect(!doc.blocks[0].kind.list.plain);
    try testing.expect(doc.blocks[1].kind.list.plain);
}

test "raw list: nests inside a bulleted list by indentation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "- a\n  . a1\n- b", .empty);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expect(list.items[0].tail[0].list.plain);
}

test "raw list: interrupts an open paragraph; near-misses stay prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "text\n. item", .empty);
    try testing.expectEqual(@as(usize, 2), d1.blocks.len);
    try testing.expect(d1.blocks[1].kind == .list);
    // `.item` (no space) and `...` are ordinary prose.
    const d2 = try parse(arena_state.allocator(), ".item\n\n...", .empty);
    try testing.expectEqual(@as(usize, 2), d2.blocks.len);
    try testing.expect(d2.blocks[0].kind == .paragraph);
    try testing.expect(d2.blocks[1].kind == .paragraph);
}

test "flow runs: slicing inlines survive the buffer being reused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `.code`/`.link.url` slice their input, and list items share one flow
    // buffer — so an earlier item's slices must not point into memory a later
    // item overwrites (they rendered as binary garbage before `parseFlowRun`).
    const list = (try parse(arena, "- [a](one.md) `code`\n- [b](two.md) `more`\n- [c](three.md) `x`", .empty)).blocks[0].kind.list;
    try testing.expectEqualStrings("one.md", list.items[0].text[0].link.url);
    try testing.expectEqualStrings("code", list.items[0].text[2].code);
    try testing.expectEqualStrings("two.md", list.items[1].text[0].link.url);
    try testing.expectEqualStrings("more", list.items[1].text[2].code);
    // Quote paragraphs share a buffer the same way.
    const quote = (try parse(arena, "> [a](one.md) `code`\n>\n> [b](two.md) `more`", .empty)).blocks[0].kind.quote;
    try testing.expectEqualStrings("one.md", quote.paras[0][0].link.url);
    try testing.expectEqualStrings("code", quote.paras[0][2].code);
    try testing.expectEqualStrings("two.md", quote.paras[1][0].link.url);
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

test "table cells: `\\|` unescapes at split time, `\\\\|` still delimits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    // One cell whose code span holds a real pipe. The escape has to come off
    // here, because the code body is never inline-parsed afterwards.
    const code = (try parse(arena, "| `a\\|b` |\n|---|", .empty)).blocks[0].kind.table;
    try testing.expectEqual(@as(usize, 1), code.header.len);
    try testing.expectEqualStrings("a|b", code.header[0][0].code);

    // A backslash consumes the byte after it, so the pipe here is a delimiter
    // and the first cell keeps a literal backslash.
    const esc = (try parse(arena, "| a\\\\|b |\n|---|---|", .empty)).blocks[0].kind.table;
    try testing.expectEqual(@as(usize, 2), esc.header.len);
    try testing.expectEqualStrings("a\\", esc.header[0][0].text);
    try testing.expectEqualStrings("b", esc.header[1][0].text);

    // Unescaped pipes split even inside backticks — GFM's rule, kept so a
    // table renders identically here and on GitHub.
    const raw = (try parse(arena, "| `a|b` |\n|---|---|", .empty)).blocks[0].kind.table;
    try testing.expectEqual(@as(usize, 2), raw.header.len);
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
    try testing.expectEqual(@as(usize, 1), quote.paras.len);
    try testing.expectEqual(@as(?Alert, null), quote.alert);
}

test "quote: a bare > line splits paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> a\n>\n> b", .empty);
    const quote = doc.blocks[0].kind.quote;
    try testing.expectEqual(@as(usize, 2), quote.paras.len);
}

test "quote: a plain line lazily continues the quote until a blank line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> a\nb\n\nafter", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].kind.quote.paras.len);
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

test "alert: a [!TYPE] first line types the quote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> [!NOTE]\n> body a\n> body b", .empty);
    const quote = doc.blocks[0].kind.quote;
    try testing.expectEqual(@as(?Alert, .note), quote.alert);
    try testing.expectEqual(@as(usize, 1), quote.paras.len);
}

test "alert: same-line text starts the first paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> [!warning] one-liner", .empty);
    const quote = doc.blocks[0].kind.quote;
    try testing.expectEqual(@as(?Alert, .warning), quote.alert);
    try testing.expectEqual(@as(usize, 1), quote.paras.len);
    try testing.expectEqualStrings("one-liner", quote.paras[0][0].text);
}

test "alert: unknown type and non-first markers stay literal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "> [!IDEA] hm", .empty);
    try testing.expectEqual(@as(?Alert, null), d1.blocks[0].kind.quote.alert);
    const d2 = try parse(arena_state.allocator(), "> before\n> [!NOTE] late", .empty);
    try testing.expectEqual(@as(?Alert, null), d2.blocks[0].kind.quote.alert);
    // No space after the marker: literal.
    const d3 = try parse(arena_state.allocator(), "> [!NOTE]x", .empty);
    try testing.expectEqual(@as(?Alert, null), d3.blocks[0].kind.quote.alert);
}

test "alert: marker plus bare > still splits paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "> [!tip]\n> a\n>\n> b", .empty);
    const quote = doc.blocks[0].kind.quote;
    try testing.expectEqual(@as(?Alert, .tip), quote.alert);
    try testing.expectEqual(@as(usize, 2), quote.paras.len);
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
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].attrs.columns.?);
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
    try testing.expect(doc.blocks[0].attrs.columns == null);
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
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].attrs.columns.?);
    try testing.expectEqual(@as(usize, 2), outer.sections.len);
    // separators still bind to the innermost group…
    const inner = outer.sections[0][0];
    try testing.expectEqualStrings("inner", inner.kind.group.name);
    try testing.expectEqual(@as(usize, 2), inner.kind.group.sections.len);
    // …but the layout-level rule strips the grid-in-grid, with a warning.
    try testing.expect(inner.attrs.columns == null);
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
    try testing.expectEqual(@as(usize, 2), d1.blocks[0].attrs.columns.?);
    const d1_inner = d1.blocks[0].kind.group.sections[0][0];
    try testing.expectEqual(@as(usize, 50), d1_inner.attrs.width_pct.?);
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
    const d2_inner = d2.blocks[0].kind.group.sections[0][0];
    try testing.expectEqual(@as(usize, 2), d2_inner.attrs.columns.?);
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
    const d1_inner = d1.blocks[0].kind.group.sections[0][0];
    try testing.expect(d1_inner.attrs.width_pct == null);
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
        .sections[0][0]; // deep
    try testing.expect(deep.attrs.width_pct == null);
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
    const inner = doc.blocks[0].kind.group.sections[0][0];
    try testing.expect(inner.attrs.columns == null);
    try testing.expectEqual(@as(usize, 50), inner.attrs.width_pct.?);
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
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].attrs.columns.?);
    try testing.expectEqual(@as(usize, 2), doc.blocks[1].attrs.columns.?);
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
    try testing.expect(doc.blocks[0].attrs.columns == null);
    try testing.expectEqual(@as(usize, 2), wrapper.sections[0][0].attrs.columns.?);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "skinny command: on groups, with grid, and bare default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// box skinny(50%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 50), d1.blocks[0].attrs.width_pct.?);
    const d2 = try parse(arena_state.allocator(), "// skinny()\n\npara", .empty);
    try testing.expectEqualStrings("", d2.blocks[0].kind.group.name);
    try testing.expectEqual(@as(usize, 75), d2.blocks[0].attrs.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "// g grid(2) skinny(80%)\na\n// --\nb\n// end", .empty);
    try testing.expectEqual(@as(usize, 2), d3.blocks[0].attrs.columns.?);
    try testing.expectEqual(@as(usize, 80), d3.blocks[0].attrs.width_pct.?);
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

test "wide command: on groups, bare default, and as a single command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// figure wide(150%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 150), d1.blocks[0].attrs.width_pct.?);
    const d2 = try parse(arena_state.allocator(), "// wide()\n\npara", .empty);
    try testing.expectEqualStrings("", d2.blocks[0].kind.group.name);
    try testing.expectEqual(@as(usize, 125), d2.blocks[0].attrs.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "/wide(140%)\n\n| a | b |\n| --- | --- |\n| 1 | 2 |", .empty);
    try testing.expectEqual(@as(usize, 140), d3.blocks[0].attrs.width_pct.?);
    try testing.expect(d3.blocks[0].kind.group.sections[0][0].kind == .table);
    try testing.expectEqual(@as(usize, 0), d3.warnings.len);
}

test "wide command: malformed args and skinny's range deactivate the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{
        "// g wide(150)", // the % is required
        "// g wide(100%)", // 100 and below belongs to skinny
        "// g wide(0%)",
        "// g wide(300%)", // above the 200% ceiling
        "// g wide(x%)",
    }) |src| {
        const doc = try parse(arena_state.allocator(), src, .empty);
        try testing.expect(doc.blocks[0].kind == .paragraph);
    }
    // The boundaries themselves: 101% is the narrowest wide, 200% the widest.
    const d1 = try parse(arena_state.allocator(), "// g wide(101%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 101), d1.blocks[0].attrs.width_pct.?);
    const d2 = try parse(arena_state.allocator(), "// g wide(200%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 200), d2.blocks[0].attrs.width_pct.?);
}

test "wide is layout: wide-in-wide strips, skinny inside wide survives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(),
        \\// outer wide(150%)
        \\
        \\// inner wide(120%)
        \\a
        \\// end
        \\
        \\// end outer
    , .empty);
    const inner1 = d1.blocks[0].kind.group.sections[0][0];
    try testing.expect(inner1.attrs.width_pct == null);
    try testing.expectEqual(@as(usize, 1), d1.warnings.len);
    // Separate counters: narrowing something inside a widened group is
    // meaningful, so it is never stripped.
    const d2 = try parse(arena_state.allocator(),
        \\// outer wide(150%)
        \\
        \\// inner skinny(50%)
        \\a
        \\// end
        \\
        \\// end outer
    , .empty);
    const inner2 = d2.blocks[0].kind.group.sections[0][0];
    try testing.expectEqual(@as(usize, 50), inner2.attrs.width_pct.?);
    try testing.expectEqual(@as(usize, 0), d2.warnings.len);
}

test "wide and skinny share one width field: the last command on the opener wins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// g skinny(50%) wide(150%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 150), d1.blocks[0].attrs.width_pct.?);
    const d2 = try parse(arena_state.allocator(), "// g wide(150%) skinny(50%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 50), d2.blocks[0].attrs.width_pct.?);
}

test "center command: on groups, with other commands, and as a single command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// box center()\n\npara", .empty);
    try testing.expect(d1.blocks[0].attrs.centered);
    const d2 = try parse(arena_state.allocator(), "// g center() skinny(50%)\n\npara", .empty);
    try testing.expect(d2.blocks[0].attrs.centered);
    try testing.expectEqual(@as(usize, 50), d2.blocks[0].attrs.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "/center()\n\n### heading", .empty);
    const g3 = d3.blocks[0].kind.group;
    try testing.expect(d3.blocks[0].attrs.centered);
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
    const inner = d2.blocks[0].kind.group.sections[0][0];
    try testing.expect(!inner.attrs.centered);
    try testing.expectEqual(@as(usize, 1), d2.warnings.len);
    try testing.expectEqualStrings(
        "group 'inner': center ignored (already inside a center)",
        d2.warnings[0],
    );
}

test "collapse command: closed default, open arg, on groups and as a single command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// faq collapse()\n\n**Q**\n\nA\n\n// end faq", .empty);
    try testing.expectEqual(@as(?Collapse, .closed), d1.blocks[0].attrs.collapse);
    const d2 = try parse(arena_state.allocator(), "/collapse(open)\n\nonly", .empty);
    try testing.expectEqual(@as(?Collapse, .open), d2.blocks[0].attrs.collapse);
    try testing.expect(d2.blocks[0].kind.group.sections[0][0].kind == .paragraph);
}

test "collapse command: bad args deactivate the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// g collapse(true)", .empty);
    try testing.expect(d1.blocks[0].kind == .paragraph);
    const d2 = try parse(arena_state.allocator(), "/collapse(5)\n\npara", .empty);
    try testing.expect(d2.blocks[0].kind == .paragraph);
}

test "collapse is layout: collapse-in-collapse is stripped with a warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\// outer collapse()
        \\
        \\lead
        \\
        \\// inner collapse()
        \\a
        \\// end
        \\
        \\// end outer
    , .empty);
    const inner = doc.blocks[0].kind.group.sections[0][1];
    try testing.expectEqual(@as(?Collapse, null), inner.attrs.collapse);
    try testing.expectEqual(@as(usize, 1), doc.warnings.len);
    try testing.expectEqualStrings(
        "group 'inner': collapse ignored (already inside a collapse)",
        doc.warnings[0],
    );
}

test "collapse is structural: anyStyle skips it, any sees it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// g collapse()\n\nlead\n\nbody\n\n// end g", .empty);
    try testing.expect(doc.blocks[0].attrs.any());
    try testing.expect(!doc.blocks[0].attrs.anyStyle());
}

test "single command: applies to the very next content element" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "/skinny(50%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const group = doc.blocks[0].kind.group;
    try testing.expectEqualStrings("", group.name);
    try testing.expectEqual(@as(usize, 50), doc.blocks[0].attrs.width_pct.?);
    try testing.expectEqual(@as(usize, 1), group.sections.len);
    try testing.expectEqual(@as(usize, 1), group.sections[0].len);
    try testing.expect(group.sections[0][0].kind == .paragraph);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "single command: /grid on one element applies but warns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "/grid(2)\npara", .empty);
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].attrs.columns.?);
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
    try testing.expectEqual(@as(usize, 50), d.blocks[0].attrs.width_pct.?);
    try testing.expectEqual(@as(usize, 1), outer.sections.len);
    try testing.expectEqual(@as(usize, 1), outer.sections[0].len);
    const inner = outer.sections[0][0];
    try testing.expectEqual(TextColor.accent, inner.attrs.text_color.?);
    try testing.expectEqual(@as(usize, 1), inner.kind.group.sections.len);
    try testing.expectEqual(@as(usize, 1), inner.kind.group.sections[0].len);
    try testing.expect(inner.kind.group.sections[0][0].kind == .paragraph);

    // A repeated layout command in the chain still hits the layout-level
    // rule: the inner `skinny` is stripped and warned, exactly as it would
    // be nested two `//` groups deep.
    const d2 = try parse(arena_state.allocator(), "/skinny(50%)\n/skinny(60%)\npara", .empty);
    try testing.expectEqual(@as(usize, 1), d2.blocks.len);
    const outer2 = d2.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 50), d2.blocks[0].attrs.width_pct.?);
    const inner2 = outer2.sections[0][0];
    try testing.expect(inner2.attrs.width_pct == null);
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
    const wrapped = outer.sections[0][0];
    try testing.expectEqual(@as(usize, 50), wrapped.attrs.width_pct.?);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
}

test "single command inside a laid-out group: the same command is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), "// box skinny(80%)\n/skinny(50%)\na\n// end", .empty);
    const wrapped = doc.blocks[0].kind.group.sections[0][0];
    try testing.expect(wrapped.attrs.width_pct == null);
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

test "slugify keeps non-ASCII text instead of dropping it" {
    const gpa = testing.allocator;
    // Accented Latin: the whole word survives, ASCII still lowercases.
    const s1 = try slugify(gpa, "Café");
    defer gpa.free(s1);
    try testing.expectEqualStrings("café", s1);
    // A script with no ASCII at all used to slug to the "section" fallback.
    const s2 = try slugify(gpa, "中文");
    defer gpa.free(s2);
    try testing.expectEqualStrings("中文", s2);
    // Mixed text: ASCII punctuation still collapses to one dash, and ASCII
    // still lowercases while non-ASCII keeps its case (no Unicode tables).
    const s3 = try slugify(gpa, "Über: die Größe!");
    defer gpa.free(s3);
    try testing.expectEqualStrings("Über-die-größe", s3);
    // Two distinct non-Latin headings no longer collide on "section".
    const s4 = try slugify(gpa, "日本語");
    defer gpa.free(s4);
    try testing.expect(!std.mem.eql(u8, s2, s4));
}

test "color command: on groups, with other commands, and as a single command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// note color(muted)\n\npara", .empty);
    try testing.expectEqual(TextColor.muted, d1.blocks[0].attrs.text_color.?);
    const d2 = try parse(arena_state.allocator(), "// g color(accent) skinny(50%)\n\npara", .empty);
    try testing.expectEqual(TextColor.accent, d2.blocks[0].attrs.text_color.?);
    try testing.expectEqual(@as(usize, 50), d2.blocks[0].attrs.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "/color(fg)\n\n### heading", .empty);
    const g3 = d3.blocks[0].kind.group;
    try testing.expectEqual(TextColor.fg, d3.blocks[0].attrs.text_color.?);
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
    try testing.expectEqual(TextColor.muted, doc.blocks[0].attrs.text_color.?);
    const inner = doc.blocks[0].kind.group.sections[0][0];
    try testing.expectEqual(TextColor.accent, inner.attrs.text_color.?);
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

test "attrs: content elements parse with empty attrs; only group blocks carry them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\# h
        \\
        \\para
        \\
        \\/center()
        \\styled
    , .empty);
    try testing.expect(!doc.blocks[0].attrs.any()); // heading
    try testing.expect(!doc.blocks[1].attrs.any()); // paragraph
    try testing.expect(doc.blocks[2].attrs.centered); // the /center() group
    // …and the wrapped paragraph inside the group is itself unstyled.
    try testing.expect(!doc.blocks[2].kind.group.sections[0][0].attrs.any());
}

test "skinny command: boundary percents — 1% and 100% valid, 101% deactivates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// g skinny(1%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 1), d1.blocks[0].attrs.width_pct.?);
    const d2 = try parse(arena_state.allocator(), "// g skinny(100%)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 100), d2.blocks[0].attrs.width_pct.?);
    const d3 = try parse(arena_state.allocator(), "// g skinny(101%)\n\npara", .empty);
    try testing.expect(d3.blocks[0].kind == .paragraph);
}

test "grid command: grid(0) deactivates the line, grid(1) is a valid single column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// g grid(0)\n\npara", .empty);
    try testing.expect(d1.blocks[0].kind == .paragraph);
    const d2 = try parse(arena_state.allocator(), "// g grid(1)\n\npara\n\n// end g", .empty);
    try testing.expectEqual(@as(usize, 1), d2.blocks[0].attrs.columns.?);
    try testing.expectEqual(@as(usize, 0), d2.warnings.len);
}

test "inline precedence: code wins over link and math openers inside its span" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // A backtick span swallows `[` — no link parses inside code.
    const d1 = try parse(arena_state.allocator(), "a `[not](a-link)` b", .empty);
    const p1 = d1.blocks[0].kind.paragraph;
    try testing.expectEqualStrings("[not](a-link)", p1[1].code);
    // Inline parsing is left-to-right: an earlier `[` takes the first
    // `](…)` even across a backtick — precedence order only breaks ties at
    // the same position.
    const d2 = try parse(arena_state.allocator(), "[x `](url)` y", .empty);
    const p2 = d2.blocks[0].kind.paragraph;
    try testing.expect(p2[0] == .link);
    try testing.expectEqualStrings("url", p2[0].link.url);
    try testing.expectEqualStrings("x `", p2[0].link.children[0].text);
    // Code beats math when the backtick comes first; the `$` stays literal.
    const d3 = try parse(arena_state.allocator(), "`$x$`", .empty);
    try testing.expectEqualStrings("$x$", d3.blocks[0].kind.paragraph[0].code);
    // Math beats code when the `$` comes first.
    const d4 = try parse(arena_state.allocator(), "$`x`$", .empty);
    try testing.expectEqualStrings("`x`", d4.blocks[0].kind.paragraph[0].math);
}

test "inline precedence: image beats link at `![`, color span needs its exact form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "![alt](src)", .empty);
    try testing.expect(d1.blocks[0].kind.paragraph[0] == .image);
    // `[text](url)` parses as a link even when a `.color(` follows a later
    // bracket group — the link arm runs before the color-span arm.
    const d2 = try parse(arena_state.allocator(), "[a](u) [b].color(muted)", .empty);
    const p2 = d2.blocks[0].kind.paragraph;
    try testing.expect(p2[0] == .link);
    try testing.expect(p2[2] == .color_span);
}

// ---- flanking (docs/reference/design/014-flanking.md) ----

/// A paragraph that parsed to exactly one literal `.text` run — i.e. every
/// delimiter in it stayed prose.
fn expectAllLiteral(arena: Allocator, src: []const u8) !void {
    const doc = try parse(arena, src, .empty);
    const p = doc.blocks[0].kind.paragraph;
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p[0] == .text);
    try testing.expectEqualStrings(src, p[0].text);
}

test "flanking: space-flanked emphasis delimiters stay literal asterisks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectAllLiteral(arena, "a * b * c");
    try expectAllLiteral(arena, "5 * 4 * 3");
    try expectAllLiteral(arena, "~~ not strike ~~");
}

test "flanking: emphasis still parses where the delimiters hug their content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d1 = try parse(arena, "*emphasis*", .empty);
    try testing.expect(d1.blocks[0].kind.paragraph[0] == .em);
    const d2 = try parse(arena, "**bold**", .empty);
    try testing.expect(d2.blocks[0].kind.paragraph[0] == .strong);
    const d3 = try parse(arena, "***both***", .empty);
    try testing.expect(d3.blocks[0].kind.paragraph[0] == .strong_em);
    const d4 = try parse(arena, "~~struck~~", .empty);
    try testing.expect(d4.blocks[0].kind.paragraph[0] == .strike);
    // The punctuation clause: a quote or paren right after the opener is fine
    // because whitespace precedes the run.
    const d5 = try parse(arena, "**\"quoted\"**", .empty);
    try testing.expect(d5.blocks[0].kind.paragraph[0] == .strong);
    // Intraword emphasis is legal for `*` (only `_` is restricted, and strike
    // has no `_` emphasis at all).
    const d6 = try parse(arena, "intra*word*em", .empty);
    try testing.expect(d6.blocks[0].kind.paragraph[1] == .em);
}

test "flanking: a non-closing candidate is skipped, not fatal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // The middle `*` can't close (space before it), so the scan continues to
    // the final one: one emphasis containing a literal asterisk.
    const doc = try parse(arena_state.allocator(), "*a * b*", .empty);
    const p = doc.blocks[0].kind.paragraph;
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p[0] == .em);
    try testing.expectEqualStrings("a * b", p[0].em[0].text);
}

test "flanking: prose dollars are not inline math" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A digit after the closing candidate rules it out (the money case).
    try expectAllLiteral(arena, "The book costs $5 and the pen costs $10.");
    try expectAllLiteral(arena, "then $HOME and $PATH are set");
    // Space after the opener, and space before the closer.
    try expectAllLiteral(arena, "$ x $");
    try expectAllLiteral(arena, "a $x $ b");
}

test "flanking: real inline math still parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d1 = try parse(arena, "real math $x^2$ inline", .empty);
    try testing.expectEqualStrings("x^2", d1.blocks[0].kind.paragraph[1].math);
    const d2 = try parse(arena, "$\\frac{a}{b}$", .empty);
    try testing.expectEqualStrings("\\frac{a}{b}", d2.blocks[0].kind.paragraph[0].math);
    // `$$` is not an empty inline-math span (display math is a block form).
    try expectAllLiteral(arena, "a $$ b");
}

// ---- paragraph indentation (docs/reference/design/015-paragraph-indent.md) ----

test "indent: any leading whitespace indents a paragraph one step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The amount and kind are deliberately not significant — all one step.
    for ([_][]const u8{ " one space", "  two spaces", "    four spaces", "\ttab", "\t\ttwo tabs" }) |src| {
        const doc = try parse(arena, src, .empty);
        try testing.expect(doc.blocks[0].kind == .paragraph);
        try testing.expectEqual(@as(usize, 1), doc.blocks[0].attrs.indent);
    }
    // A flush paragraph carries no indent…
    const flush = try parse(arena, "flush", .empty);
    try testing.expectEqual(@as(usize, 0), flush.blocks[0].attrs.indent);
    // …and the leading whitespace never reaches the rendered text.
    const doc = try parse(arena, "\tindented paragraph", .empty);
    try testing.expectEqualStrings("indented paragraph", doc.blocks[0].kind.paragraph[0].text);
}

test "indent: only paragraphs respond to leading whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Every other block form ignores it and parses exactly as it would flush.
    const cases = [_][]const u8{
        "  ## heading",
        "\t> quote",
        "  - item",
        "\t. raw item",
        "  ```\ncode\n```",
        "\t$$x$$",
        "  ---",
    };
    for (cases) |src| {
        const doc = try parse(arena, src, .empty);
        try testing.expect(doc.blocks[0].kind != .paragraph);
        try testing.expectEqual(@as(usize, 0), doc.blocks[0].attrs.indent);
    }
    // Directives too: an indented opener is live, and carries no indent of
    // its own (a tab reads exactly like the spaces that always worked here).
    const g = try parse(arena, "\t// g grid(2)\n\nx\n\n// end g", .empty);
    try testing.expect(g.blocks[0].kind == .group);
    try testing.expectEqual(@as(usize, 0), g.blocks[0].attrs.indent);
}

test "indent: an indented continuation line soft-wraps instead of indenting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Only a paragraph's *first* line is read, so wrapped prose can never
    // accidentally indent — the indented line joins the open paragraph.
    const d1 = try parse(arena, "flow\n\tindented", .empty);
    try testing.expectEqual(@as(usize, 1), d1.blocks.len);
    try testing.expectEqual(@as(usize, 0), d1.blocks[0].attrs.indent);
    try testing.expectEqualStrings("flow indented", d1.blocks[0].kind.paragraph[0].text);
    // With a blank line between, the second paragraph is its own block and
    // does indent.
    const d2 = try parse(arena, "flow\n\n\tindented", .empty);
    try testing.expectEqual(@as(usize, 2), d2.blocks.len);
    try testing.expectEqual(@as(usize, 0), d2.blocks[0].attrs.indent);
    try testing.expectEqual(@as(usize, 1), d2.blocks[1].attrs.indent);
}

test "indent: an indented line inside a list continues the item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // The old tab-prefix form claimed to interrupt a list item but was
    // swallowed by it (note 015's Problem section); now there is no
    // whitespace-led block form at all, and continuation is the whole story.
    const doc = try parse(arena_state.allocator(), "- item\n\tcontinued", .empty);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const list = doc.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("item continued", list.items[0].text[0].text);
}

test "indent command: bare indent() is one step, indent(0) deactivates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// g indent()\n\npara\n\n// end g", .empty);
    try testing.expectEqual(@as(usize, 1), d1.blocks[0].attrs.indent);
    const d2 = try parse(arena_state.allocator(), "/indent(3)\n\npara", .empty);
    try testing.expectEqual(@as(usize, 3), d2.blocks[0].attrs.indent);
    const d3 = try parse(arena_state.allocator(), "/indent(0)\n\npara", .empty);
    try testing.expect(d3.blocks[0].kind == .paragraph);
    try testing.expect(!d3.blocks[0].attrs.any());
}

test "indent is non-layout: indent-in-indent nests without stripping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// outer indent()\n\n// inner indent(2)\n\npara\n\n// end inner\n\n// end outer", .empty);
    try testing.expectEqual(@as(usize, 1), d.blocks[0].attrs.indent);
    const inner = d.blocks[0].kind.group.sections[0][0];
    try testing.expectEqual(@as(usize, 2), inner.attrs.indent);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
}
