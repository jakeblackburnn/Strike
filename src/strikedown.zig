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
//! (see `docs/reference/design/006-color.md`), `[text].cite(refs)` citation marks
//! (see `docs/reference/design/016-citations.md`), `<http…>` and bare-URL autolinks,
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


const model = @import("strikedown/model.zig");
const command = @import("strikedown/command.zig");
const citations = @import("strikedown/citations.zig");
const inlines = @import("strikedown/inline.zig");

// ---- re-exports: the document model lives in strikedown/model.zig, split
// out for size; every external caller keeps importing strikedown.Doc etc
// unchanged. ----------------------------------------------------------------
pub const Doc = model.Doc;
pub const Block = model.Block;
pub const Attrs = model.Attrs;
pub const Group = model.Group;
pub const TextColor = model.TextColor;
pub const Collapse = model.Collapse;
pub const CaptionPos = model.CaptionPos;
pub const Heading = model.Heading;
pub const Quote = model.Quote;
pub const Alert = model.Alert;
pub const Code = model.Code;
pub const List = model.List;
pub const Item = model.Item;
pub const Table = model.Table;
pub const Align = model.Align;
pub const Inline = model.Inline;
pub const CiteSpan = model.CiteSpan;
pub const CiteRef = model.CiteRef;
pub const alignAt = model.alignAt;

// ---- internal aliases: command vocabulary (strikedown/command.zig), the
// citations pass (strikedown/citations.zig), and inline parsing
// (strikedown/inline.zig) live in their own files; block-loop code and tests
// below keep referring to them unqualified. --------------------------------
const Command = command.Command;
const parseCommand = command.parseCommand;
const applyCommand = command.applyCommand;
const CommandTag = command.CommandTag;
const isLayout = command.isLayout;
const isStructural = command.isStructural;
const hasCommand = command.hasCommand;
const clearCommand = command.clearCommand;
const groupLabel = command.groupLabel;
const parseSingleCommandLine = command.parseSingleCommandLine;
const caption_default_split_pct = command.caption_default_split_pct;
const CommandTokenizer = command.CommandTokenizer;

const parseInlines = inlines.parseInlines;
const splitCells = inlines.splitCells;
const parseAligns = inlines.parseAligns;
const stripBoundaryPipes = inlines.stripBoundaryPipes;
const hasUrlBody = inlines.hasUrlBody;

// ---- parsing -----------------------------------------------------------------

/// Parse strikedown/markdown source into a `Doc`. `base` is the document's
/// base typography sheet (the site/project `.sxh` header, already layered by
/// `project.zig`'s `loadHeader`, or `.empty`) — its aliases are in scope for
/// the whole document, under any `:name command()*` lines the document
/// defines itself (`docs/reference/design/010-aliases.md`). Everything in
/// the returned tree is owned by `arena` (or points into `src`) — free the
/// arena as a whole, never nodes piecemeal.
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

    var p: Parser = .{ .arena = arena, .lines = lines.items, .base_sheet = base };
    var blocks: std.ArrayList(Block) = .empty;
    while (p.idx < p.lines.len) {
        if (isBlank(p.lines[p.idx])) {
            p.idx += 1;
            continue;
        }
        if (try p.next()) |block| try appendSibling(&blocks, arena, block, &p.warnings, "document");
    }
    const block_slice = try blocks.toOwnedSlice(arena);
    // The citations pass (016-citations) — the one whole-tree step after the
    // block loop: entries and marks can only meet once both exist.
    try citations.resolveCitations(arena, &p.warnings, block_slice);
    // The nesting-cap warning lands here, not where the cap was hit: a
    // reverted `/cmd()` chain shrinks the warning list, and this one must
    // survive that (and appear once however many times the cap was hit).
    if (p.depth_warned) {
        try p.warnings.append(arena, try std.fmt.allocPrint(
            arena,
            "nesting deeper than {d} levels; deeper structure flattens to prose",
            .{max_nest_depth},
        ));
    }
    return .{
        .blocks = block_slice,
        .warnings = try p.warnings.toOwnedSlice(arena),
    };
}

/// The nesting cap for the recursive block parsers (groups, single-command
/// chains, list levels — one stack frame each, and the citations pass and
/// emitters mirror the tree's depth). Structure past the cap degrades to
/// prose/flat with a warning; without a cap a generated document (tens of
/// thousands of `// a` lines) overflows the stack instead of parsing.
const max_nest_depth = 64;

const Parser = struct {
    arena: Allocator,
    /// The document's lines, raw (untrimmed) — block parsers trim as they
    /// classify, and the paragraph arm reads the raw form to see a leading
    /// whitespace indent (note 015).
    lines: [][]const u8,
    idx: usize = 0,
    /// Current recursion depth of the block parsers, against `max_nest_depth`.
    depth: usize = 0,
    depth_warned: bool = false,
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
    /// The document's header sheet — site `.sxh` layered under project
    /// `.sxh` (`project.zig`'s `loadHeader`, concatenated before `parse` is
    /// called). Alias lookups check this after in-document definitions.
    base_sheet: sheet.Sheet = .empty,
    /// Aliases defined so far by `:name command()*` lines in this document,
    /// in source order — a use before its definition sees a plain name/prose
    /// (the parser is single-pass), matching `docs/reference/design/010-aliases.md`.
    doc_aliases: std.ArrayList(sheet.NamedAlias) = .empty,

    /// Parse the block starting at `idx` (which is non-blank), advancing past
    /// it. Returns null for lines consumed without producing a block
    /// (typography directives).
    fn next(p: *Parser) Allocator.Error!?Block {
        const t = trimIndent(p.lines[p.idx]);

        // Typography directive (`:` line): a clean `:name command()*` line
        // defines an alias (added to this document's sheet) and emits
        // nothing; anything else is not a directive at all (stays prose,
        // handled by `parseBlock`/`parseParagraph`).
        if (sheet.parseLine(t)) |d| {
            switch (d) {
                .alias => |a| try p.doc_aliases.append(p.arena, a),
            }
            p.idx += 1;
            return null;
        }

        return try p.parseBlock(t);
    }

    /// Resolve one `word(args)` token to `Attrs`: a real command via
    /// `parseCommand`, else — args empty, word alias-shaped — an alias this
    /// document knows (`docs/reference/design/010-aliases.md`, candidate B: a
    /// `name()` use looks exactly like a command, so it enters through this
    /// same lookup with no separate grammar). Null means neither — the token
    /// stays what it always meant: unrecognized, deactivating the directive.
    fn resolveCommandToken(p: *Parser, tok: []const u8) ?Attrs {
        if (parseCommand(tok)) |cmd| {
            var attrs: Attrs = .{};
            applyCommand(&attrs, cmd);
            return attrs;
        }
        if (tok.len < 3 or tok[tok.len - 1] != ')') return null;
        const paren = std.mem.indexOfScalar(u8, tok, '(') orelse return null;
        const word = tok[0..paren];
        if (tok[paren + 1 .. tok.len - 1].len != 0) return null; // aliases take no arguments
        if (!sheet.isAliasName(word)) return null;
        return p.lookupAlias(word);
    }

    /// Classify a (left-trimmed) line as a single-command directive
    /// (`docs/reference/design/002-single-command.md`) and resolve it: `/`
    /// immediately followed by exactly one command-or-alias token and
    /// nothing else. The char after the slash keeps the two directive
    /// families apart (`//` is a group line), and `resolveCommandToken`'s
    /// strictness is the degradation story — `/usr/bin/env`, `/skinny (50%)`,
    /// or trailing words all return null and stay prose.
    fn resolveSingleCommandLine(p: *Parser, t: []const u8) ?Attrs {
        if (t.len < 2 or t[0] != '/' or t[1] == '/') return null;
        return p.resolveCommandToken(std.mem.trimEnd(u8, t[1..], " "));
    }

    /// Search in-document aliases (most recent definition wins), then the
    /// header sheet.
    fn lookupAlias(p: *Parser, name: []const u8) ?Attrs {
        var i = p.doc_aliases.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.doc_aliases.items[i].name, name)) return p.doc_aliases.items[i].attrs;
        }
        return p.base_sheet.get(name);
    }

    /// The block classification chain: `t` is the current line, left-trimmed
    /// (and prefix-stripped, when a color prefix applied). The *order* is the
    /// grammar's precedence — group before single-command, rule before list —
    /// and every arm advances `p.idx` past what it consumed.
    fn parseBlock(p: *Parser, t: []const u8) Allocator.Error!Block {
        // Group directive. Only a clean *opener* starts anything here; a
        // separator/closer line is consumed inside `parseGroup`'s loop, so one
        // reaching this chain is outside any group (or mismatched) and falls
        // through to prose — the degradation rule. Past the nesting cap an
        // opener degrades the same way.
        if (parseGroupLine(p, t)) |gl| {
            if (gl == .open) {
                if (p.depth < max_nest_depth) return try p.parseGroup(gl.open);
                p.warnDepth();
            }
        }

        // Single-command directive: `/cmd(args)` (or `/alias()`) applies one
        // command to the very next content element by wrapping it in an
        // anonymous group. With nothing to bind to (EOF, or a directive
        // next), it falls through to prose — the same context-liveness rule
        // that keeps separators/closers outside a group inert.
        if (p.resolveSingleCommandLine(t)) |attrs| {
            if (try p.parseSingleCommand(attrs, true)) |block| return block;
        }

        if (std.mem.startsWith(u8, t, "```")) return p.parseCodeFence(t);
        if (std.mem.startsWith(u8, t, "$$")) return p.parseMathBlock(t);

        // ATX heading. The anchor id comes from the raw heading text (markdown
        // punctuation collapses into `-` naturally), deduped per document.
        if (headingLevel(t)) |level| {
            const text = std.mem.trim(u8, t[level..], " ");
            const slug = try p.uniqueSlug(text);
            p.idx += 1;
            return .{ .kind = .{ .heading = .{
                .level = level,
                .id = slug,
                .inlines = try parseInlines(p.arena, text),
            } } };
        }

        // Horizontal rule (checked before lists so `---` is not a list item).
        if (isHorizontalRule(t)) {
            p.idx += 1;
            return .{ .kind = .rule };
        }

        if (std.mem.startsWith(u8, t, ">")) return p.parseQuote();

        // List (unordered or ordered, possibly nested by indentation).
        if (parseMarker(t) != null) {
            return .{ .kind = .{ .list = try p.parseList() } };
        }

        if (isTableStart(p.lines, p.idx)) return p.parseTable();

        return p.parseParagraph(t);
    }

    /// Fenced code block: contents are kept verbatim, no inline parsing.
    fn parseCodeFence(p: *Parser, t: []const u8) Allocator.Error!Block {
        const arena = p.arena;
        // Info string: the first token names the language (```python);
        // anything after it is ignored.
        const info = std.mem.trim(u8, t[3..], " \t");
        const lang = info[0 .. std.mem.indexOfAny(u8, info, " \t") orelse info.len];
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

    /// Display math: `$$…$$`. The TeX is kept raw; emitters wrap it.
    fn parseMathBlock(p: *Parser, t: []const u8) Allocator.Error!Block {
        const arena = p.arena;
        const rest = std.mem.trimEnd(u8, t, " ");
        // Single-line `$$ … $$`.
        if (rest.len >= 4 and std.mem.endsWith(u8, rest, "$$")) {
            p.idx += 1;
            return .{ .kind = .{ .math = rest[2 .. rest.len - 2] } };
        }
        // A third `$` is not an opener (`$$$x` is prose, matching the
        // single-line arm's exactly-two slicing).
        if (rest.len > 2 and rest[2] == '$') return p.parseParagraph(t);
        // Multi-line: gather until a line ending in `$$`. A blank line or
        // EOF first means the opener was a stray `$$` — revert the whole
        // thing to a paragraph rather than swallowing the document.
        var buf: std.ArrayList(u8) = .empty;
        try appendMathPiece(arena, &buf, rest[2..]);
        var j = p.idx + 1;
        const end: usize = while (j < p.lines.len) {
            if (isBlank(p.lines[j])) return p.parseParagraph(t);
            const ml = std.mem.trimEnd(u8, p.lines[j], " ");
            if (std.mem.endsWith(u8, ml, "$$")) {
                try appendMathPiece(arena, &buf, ml[0 .. ml.len - 2]);
                break j + 1;
            }
            try appendMathPiece(arena, &buf, ml);
            j += 1;
        } else return p.parseParagraph(t);
        p.idx = end;
        return .{ .kind = .{ .math = try buf.toOwnedSlice(arena) } };
    }

    /// Blockquote. Consecutive `>` lines soft-merge into one flowing
    /// paragraph (the same joining rule as plain paragraphs); a bare `>`
    /// line breaks paragraphs within the quote; a plain line lazily
    /// continues the open quote paragraph (GFM lazy continuation). A
    /// blank line — or any new block form — ends the quote.
    fn parseQuote(p: *Parser) Allocator.Error!Block {
        const arena = p.arena;
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

    /// GFM pipe table: the header row and `|---|` separator row the caller's
    /// `isTableStart` lookahead already verified, then body rows until a
    /// blank/pipeless line or a new block.
    fn parseTable(p: *Parser) Allocator.Error!Block {
        const arena = p.arena;
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

    /// Paragraph: gather consecutive lines until a blank line or a new block.
    /// Leading whitespace on the paragraph's *first* line indents it one
    /// step (015-paragraph-indent) — the raw line is read before trimming,
    /// and only here, which is what confines the rule to paragraphs.
    /// Continuation lines soft-wrap regardless of their own indentation.
    fn parseParagraph(p: *Parser, t: []const u8) Allocator.Error!Block {
        const arena = p.arena;
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
        p.depth += 1;
        defer p.depth -= 1;
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
                    if (p.depth < max_nest_depth) {
                        try flushFlow(arena, &flow, &items, &tail);
                        try tail.append(arena, .{ .list = try p.parseList() });
                        continue;
                    }
                    // Past the cap: no deeper child — the item joins this
                    // level instead (flattened), via the sibling path below.
                    p.warnDepth();
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
        p.depth += 1;
        defer p.depth -= 1;
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
            if (parseGroupLine(p, t)) |gl| switch (gl) {
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
                } else {
                    // A closer naming a different group stays prose inside
                    // this one (the degradation rule) — but silently, it
                    // reads like data loss; say what happened.
                    try p.warnings.append(arena, try std.fmt.allocPrint(
                        arena,
                        "group '{s}': mismatched closer '// end {s}' treated as prose",
                        .{ groupLabel(open.name), name.? },
                    ));
                },
                .open => {}, // a nested group; `next()` below recurses into it
            };
            if (try p.next()) |block| try appendSibling(&cur, arena, block, &p.warnings, groupLabel(open.name));
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
    /// path as `//` groups. `attrs_in` is the resolved command (or alias,
    /// `docs/reference/design/010-aliases.md`) — a whole precomputed `Attrs`,
    /// not a `Command`, so an alias that bundles several commands applies
    /// them all in one bind. Returns null (the line stays prose) when there
    /// is nothing to bind to: EOF, or a `:`/`//` directive next. A chain of
    /// `/command()` lines recurses — each wraps the next, down to the
    /// eventual content element — so `/skinny() /color(accent) text` nests
    /// exactly as the equivalent nested groups would (layout-level rule and
    /// all: a repeated layout command in the chain still strips and warns).
    ///
    /// `is_root` is true only for the outermost call, from `parseBlock` —
    /// the one whose returned block reaches `appendSibling` in the caller's
    /// own sibling list (the top-level loop, or a group's section loop), the
    /// only place a preceding sibling exists to pop. `snug()` needs exactly
    /// that, so it's allowed here as the chain's first token — `/snug()`
    /// backward-attaches to whatever precedes it, same as `// snug() ...
    /// // end` would. Nested deeper in a chain (`/color(accent) /snug()
    /// text`) there is no preceding-sibling list at that frame — the chain
    /// reverts to prose instead, same as `caption()`, which is never valid
    /// here at all: its position argument implies deliberate figure/
    /// figcaption boundaries a `/cmd()` line can't express.
    fn parseSingleCommand(p: *Parser, attrs_in: Attrs, is_root: bool) Allocator.Error!?Block {
        const arena = p.arena;
        if (attrs_in.caption_pos != null) return null;
        if (attrs_in.snug and !is_root) return null;
        if (p.depth >= max_nest_depth) {
            p.warnDepth();
            return null; // the line stays prose, like any unbound command
        }
        p.depth += 1;
        defer p.depth -= 1;
        const saved_idx = p.idx;
        const saved_warnings = p.warnings.items.len;
        var j = p.idx + 1;
        while (j < p.lines.len and isBlank(p.lines[j])) j += 1;
        if (j >= p.lines.len) return null;
        const nt = trimIndent(p.lines[j]);
        if (p.isGroupInterrupt(nt) or sheet.parseLine(nt) != null) return null;

        var attrs = attrs_in;
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
        const inner = if (p.resolveSingleCommandLine(nt)) |next_attrs|
            (try p.parseSingleCommand(next_attrs, false)) orelse {
                p.idx = saved_idx;
                // The whole chain reverts to prose — drop any warnings
                // appended above on the assumption that it would bind.
                p.warnings.shrinkRetainingCapacity(saved_warnings);
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

    /// Note that the nesting cap was hit; `parse` appends the one warning at
    /// the end (appending here would warn per hit, and a reverted `/cmd()`
    /// chain's warning-list shrink could silently swallow it).
    fn warnDepth(p: *Parser) void {
        p.depth_warned = true;
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
        const gl = parseGroupLine(p, t) orelse return false;
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
    if (items.items.len == 0) {
        // No open item to flush into (unreachable today — flow only fills
        // after an item opens). Drop the run: leaving it buffered would
        // splice it into the *next* item's text.
        flow.clearRetainingCapacity();
        return;
    }
    if (flow.items.len == 0) return;
    const inls = try parseFlowRun(arena, flow.items);
    flow.clearRetainingCapacity();
    if (tail.items.len == 0) {
        items.items[items.items.len - 1].text = inls;
    } else {
        try tail.append(arena, .{ .line = inls });
    }
}

/// Join a display-math content piece onto `buf` with one `\n` between
/// non-empty pieces — empty opener/closer remainders contribute nothing, so
/// `$$\nx\n$$` yields `x`, not `\nx\n`.
fn appendMathPiece(arena: Allocator, buf: *std.ArrayList(u8), piece: []const u8) Allocator.Error!void {
    if (piece.len == 0) return;
    if (buf.items.len > 0) try buf.append(arena, '\n');
    try buf.appendSlice(arena, piece);
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
/// collide with names; a `word()` token that isn't a real command but names
/// an alias in scope resolves the same way (`docs/reference/design/010-aliases.md`,
/// `Parser.resolveCommandToken`). Whether a separator/closer is *live* is the
/// parser's call (they need an open group); this function only classifies.
fn parseGroupLine(p: *Parser, t: []const u8) ?GroupLine {
    if (!std.mem.startsWith(u8, t, "//")) return null;
    if (t.len > 2 and t[2] != ' ') return null;
    const rest = std.mem.trim(u8, t[2..], " ");
    if (rest.len == 0) return .bare;
    if (std.mem.eql(u8, rest, "--")) return .sep;

    var it: CommandTokenizer = .{ .rest = rest };
    const first = it.next().?; // rest is non-empty, so at least one token
    if (std.mem.eql(u8, first, "end")) {
        const name = it.next() orelse return .{ .end = null };
        if (it.next() != null) return null;
        if (!sheet.isAliasName(name)) return null;
        return .{ .end = name };
    }

    var open: GroupLine.Open = .{};
    if (p.resolveCommandToken(first)) |attrs| {
        command.mergeAttrs(&open.attrs, attrs);
    } else {
        if (!sheet.isAliasName(first) or std.mem.eql(u8, first, "--")) return null;
        open.name = first;
    }
    while (it.next()) |tok| {
        const attrs = p.resolveCommandToken(tok) orelse return null;
        command.mergeAttrs(&open.attrs, attrs);
    }
    // Two backward-attach commands on one opener both want the same popped
    // partner slot — a malformed combination, same rule as caption's own
    // split-percent-without-left/right rejection: degrade the whole line to
    // prose, silently (no warning — this is syntax-level, not runtime).
    if (open.attrs.caption_pos != null and open.attrs.snug) return null;
    return .{ .open = open };
}

/// Append `block` to a sibling-block list being accumulated by the top-level
/// parse loop or a group section — the two places that know "what came
/// immediately before" a given block; `parseGroup` itself only sees its own
/// contents, never its surroundings. A backward-attach group
/// (`attrs.backwardAttach()` — `caption` or `snug`) binds here: it pops the
/// immediately-preceding sibling out of `list` and becomes its partner as
/// section 0, with the group's own section(s) following. No preceding
/// sibling (list empty — the group opens the document, or immediately
/// follows another group's close) degrades gracefully: the group is
/// appended as-is (its own section(s) only, no partner) and a warning is
/// recorded — the emitter then renders it as a plain group (no `<figure>`/
/// `<figcaption>` for caption, no `sx-snug` seam-tightening for snug).
fn appendSibling(
    list: *std.ArrayList(Block),
    arena: Allocator,
    block: Block,
    warnings: *std.ArrayList([]const u8),
    label: []const u8,
) Allocator.Error!void {
    if (block.kind == .group and block.attrs.backwardAttach()) {
        if (list.pop()) |prev| {
            const g = block.kind.group;
            const new_sections = try arena.alloc([]Block, g.sections.len + 1);
            const leader = try arena.alloc(Block, 1);
            leader[0] = prev;
            new_sections[0] = leader;
            for (g.sections, 0..) |s, i| new_sections[i + 1] = s;
            var b2 = block;
            b2.kind.group.sections = new_sections;
            try list.append(arena, b2);
            return;
        }
        try warnings.append(arena, try std.fmt.allocPrint(
            arena,
            "backward-attach group in '{s}': no preceding element to attach to — rendered as plain content",
            .{label},
        ));
    }
    try list.append(arena, block);
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

test "a malformed `:` line (reserved word, bad args) is prose" {
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

test "cite span: [text].cite(refs) parses — positional, key, and comma lists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "a [**big** claim].cite(2) b", .empty);
    const inls = d1.blocks[0].kind.paragraph;
    try testing.expectEqual(@as(usize, 3), inls.len);
    const span = inls[1].cite_span;
    try testing.expectEqual(@as(usize, 1), span.refs.len);
    try testing.expectEqualStrings("2", span.refs[0].raw);
    try testing.expect(span.children[0] == .strong);
    // (these docs have no citations group, so every ref's `num` is zeroed by
    // the resolution pass — binding is covered by the resolution tests)
    const d2 = try parse(arena_state.allocator(), "[x].cite(knuth1984)", .empty);
    const s2 = d2.blocks[0].kind.paragraph[0].cite_span;
    try testing.expectEqualStrings("knuth1984", s2.refs[0].raw);
    // comma list, spaces allowed, digit and key refs mixed
    const d3 = try parse(arena_state.allocator(), "[x].cite(1, lamport-86,3)", .empty);
    const s3 = d3.blocks[0].kind.paragraph[0].cite_span;
    try testing.expectEqual(@as(usize, 3), s3.refs.len);
    try testing.expectEqualStrings("1", s3.refs[0].raw);
    try testing.expectEqualStrings("lamport-86", s3.refs[1].raw);
    try testing.expectEqualStrings("3", s3.refs[2].raw);
}

test "cite span: malformed forms stay literal prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // a link wins its `[`
    const d1 = try parse(arena_state.allocator(), "[label](url).cite(1)", .empty);
    const p1 = d1.blocks[0].kind.paragraph;
    try testing.expect(p1[0] == .link);
    try testing.expectEqualStrings(".cite(1)", p1[1].text);
    // empty text (reserved point form), empty/zero/dangling/spaced/bad refs,
    // unterminated args: all literal
    for ([_][]const u8{
        "[].cite(1)",
        "[x].cite()",
        "[x].cite(0)",
        "[x].cite(1,)",
        "[x].cite(a b)",
        "[x].cite(a.b)",
        "[x].cite(-)",
        "[x].cite(1",
    }) |src| {
        const doc = try parse(arena_state.allocator(), src, .empty);
        try testing.expect(doc.blocks[0].kind.paragraph[0] == .text);
    }
    // no nesting: the earliest `].cite(` closes the span
    const d2 = try parse(arena_state.allocator(), "[a [b].cite(1) c].cite(2)", .empty);
    const p2 = d2.blocks[0].kind.paragraph;
    try testing.expectEqualStrings("a [b", p2[0].cite_span.children[0].text);
    try testing.expectEqualStrings(" c].cite(2)", p2[1].text);
}

test "citations command: group and single-command forms; args deactivate the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(), "// refs citations()\n\n1. e\n\n// end refs", .empty);
    try testing.expect(d1.blocks[0].attrs.citations);
    const d2 = try parse(arena_state.allocator(), "/citations()\n\n1. e", .empty);
    try testing.expect(d2.blocks[0].attrs.citations);
    try testing.expect(d2.blocks[0].kind.group.sections[0][0].kind == .list);
    // citations takes no arguments — the whole line degrades to prose
    const d3 = try parse(arena_state.allocator(), "// citations(2)\n\n1. e", .empty);
    try testing.expect(d3.blocks[0].kind == .paragraph);
}

test "citations: marks resolve to entries with sites, backlinks, and previews" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\[Line-breaking is a dynamic program].cite(1) — predates the system.
        \\
        \\[Both agree].cite(1, 2)
        \\
        \\// citations()
        \\
        \\1. D. Knuth, *The TeXbook*, Addison-Wesley, 1984.
        \\2. L. Lamport, *LaTeX*, 1986.
        \\
        \\//
    , .empty);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
    const m1 = doc.blocks[0].kind.paragraph[0].cite_span;
    try testing.expectEqual(@as(u32, 1), m1.site);
    try testing.expectEqual(@as(u32, 1), m1.refs[0].num);
    try testing.expectEqualStrings("1. D. Knuth, The TeXbook, Addison-Wesley, 1984.", m1.preview);
    const m2 = doc.blocks[1].kind.paragraph[0].cite_span;
    try testing.expectEqual(@as(u32, 2), m2.site);
    try testing.expectEqualStrings(
        "1. D. Knuth, The TeXbook, Addison-Wesley, 1984.\n2. L. Lamport, LaTeX, 1986.",
        m2.preview,
    );
    const items = doc.blocks[2].kind.group.sections[0][0].kind.list.items;
    try testing.expectEqual(@as(u32, 1), items[0].cite_entry);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, items[0].cite_sites);
    try testing.expectEqual(@as(u32, 2), items[1].cite_entry);
    try testing.expectEqualSlices(u32, &.{2}, items[1].cite_sites);
}

test "citations: [key] entry prefixes lift and bind key refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\[claim].cite(knuth1984)
        \\
        \\// citations()
        \\
        \\1. [knuth1984] D. Knuth, *The TeXbook*, 1984.
        \\2. [1984] all digits is not a key.
        \\
        \\//
    , .empty);
    try testing.expectEqual(@as(usize, 0), doc.warnings.len);
    const mark = doc.blocks[0].kind.paragraph[0].cite_span;
    try testing.expectEqual(@as(u32, 1), mark.refs[0].num);
    const items = doc.blocks[1].kind.group.sections[0][0].kind.list.items;
    // the key prefix is lifted from the entry text; a non-key bracket stays
    try testing.expectEqualStrings("D. Knuth, ", items[0].text[0].text);
    try testing.expectEqualStrings("[1984] all digits is not a key.", items[1].text[0].text);
    try testing.expectEqualSlices(u32, &.{1}, items[0].cite_sites);
}

test "citations: unresolved refs warn and zero out; the mark still parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // out of range and unknown key, one warning each
    const d1 = try parse(arena_state.allocator(),
        \\[a].cite(9) [b].cite(nope)
        \\
        \\// citations()
        \\
        \\1. only entry
        \\
        \\//
    , .empty);
    try testing.expectEqual(@as(usize, 2), d1.warnings.len);
    const p1 = d1.blocks[0].kind.paragraph;
    try testing.expectEqual(@as(u32, 0), p1[0].cite_span.refs[0].num);
    try testing.expectEqual(@as(u32, 0), p1[2].cite_span.refs[0].num);
    // marks with no citations group anywhere: zeroed, one warning
    const d2 = try parse(arena_state.allocator(), "[a].cite(1) and [b].cite(2)", .empty);
    try testing.expectEqual(@as(usize, 1), d2.warnings.len);
    try testing.expectEqual(@as(u32, 0), d2.blocks[0].kind.paragraph[0].cite_span.refs[0].num);
}

test "citations: one group per document; extras and listless groups degrade" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(),
        \\// citations()
        \\
        \\1. first
        \\
        \\//
        \\
        \\// citations()
        \\
        \\1. second
        \\
        \\//
    , .empty);
    try testing.expectEqual(@as(usize, 1), d1.warnings.len);
    try testing.expect(d1.blocks[0].attrs.citations);
    try testing.expect(!d1.blocks[1].attrs.citations); // degraded to a plain group
    // no numbered list: the command degrades, the group renders plain
    const d2 = try parse(arena_state.allocator(), "// citations()\n\njust prose\n\n//", .empty);
    try testing.expectEqual(@as(usize, 1), d2.warnings.len);
    try testing.expect(!d2.blocks[0].attrs.citations);
    // duplicate keys: first wins, warning
    const d3 = try parse(arena_state.allocator(),
        \\// citations()
        \\
        \\1. [k] a.
        \\2. [k] b.
        \\
        \\//
    , .empty);
    try testing.expectEqual(@as(usize, 1), d3.warnings.len);
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

// ---- v0.1.0 fixes ------------------------------------------------------------

test "reverted /cmd() chains leave no warnings behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Both chains end at EOF, so every line reverts to prose — the grid
    // mismatch / nested-skinny warnings appended mid-chain must revert too.
    const d1 = try parse(arena_state.allocator(), "/grid(2)\n/color(accent)", .empty);
    try testing.expectEqual(@as(usize, 2), d1.blocks.len);
    try testing.expectEqual(@as(usize, 0), d1.warnings.len);
    const d2 = try parse(arena_state.allocator(), "/skinny(50%)\n/skinny(60%)\n/color(accent)", .empty);
    try testing.expectEqual(@as(usize, 3), d2.blocks.len);
    try testing.expectEqual(@as(usize, 0), d2.warnings.len);
}

test "nesting cap: deep group openers degrade to prose instead of overflowing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..200) |_| try src.appendSlice(arena, "// g\n");
    try src.appendSlice(arena, "x\n");
    const d = try parse(arena, src.items, .empty);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "nesting deeper than") != null);
    // The first 64 levels are real groups; walk down and confirm.
    var b = d.blocks[0];
    var depth: usize = 0;
    while (b.kind == .group) : (depth += 1) {
        const sec = b.kind.group.sections[0];
        if (sec.len == 0) break;
        b = sec[0];
    }
    try testing.expectEqual(@as(usize, max_nest_depth), depth);
}

test "nesting cap: deep lists flatten instead of overflowing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..200) |lvl| {
        try src.appendNTimes(arena, ' ', lvl * 2);
        try src.appendSlice(arena, "- a\n");
    }
    const d = try parse(arena, src.items, .empty);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
}

test "nesting cap: an over-deep /cmd() chain reverts to prose with the warning intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    // color is non-layout (nests freely), so the only expected warning is
    // the cap's — a layout command would add its own strip warnings.
    for (0..200) |_| try src.appendSlice(arena, "/color(accent)\n");
    try src.appendSlice(arena, "text\n");
    const d = try parse(arena, src.items, .empty);
    // The chain can't fully bind past the cap, so it reverts to prose —
    // but the cap warning survives the revert.
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "nesting deeper than") != null);
}

test "citations: entry numbering follows the list's start" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// refs citations()\n\n3. [a] First.\n4. Second.\n\n//\n\nClaim [x].cite(3) and [y].cite(a).", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    const list = d.blocks[0].kind.group.sections[0][0].kind.list;
    try testing.expectEqual(@as(u32, 3), list.items[0].cite_entry);
    try testing.expectEqual(@as(u32, 4), list.items[1].cite_entry);
    const para = d.blocks[1].kind.paragraph;
    // `.cite(3)` targets the *visible* entry 3, and the key ref agrees.
    try testing.expectEqual(@as(u32, 3), para[1].cite_span.refs[0].num);
    try testing.expectEqual(@as(u32, 3), para[3].cite_span.refs[0].num);
    try testing.expectEqual(@as(usize, 2), list.items[0].cite_sites.len);
}

test "citations: out-of-range, overflowing, and unknown refs all degrade per-ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// refs citations()\n\n1. Only.\n\n//\n\n[a].cite(9) [b].cite(99999999999) [c].cite(nope, 1)", .empty);
    try testing.expectEqual(@as(usize, 3), d.warnings.len);
    for (d.warnings) |w| try testing.expect(std.mem.indexOf(u8, w, "no matching entry") != null);
    const para = d.blocks[1].kind.paragraph;
    try testing.expectEqual(@as(u32, 0), para[0].cite_span.refs[0].num);
    try testing.expectEqual(@as(u32, 0), para[2].cite_span.refs[0].num);
    // The mixed mark keeps its resolved ref.
    try testing.expectEqual(@as(u32, 0), para[4].cite_span.refs[0].num);
    try testing.expectEqual(@as(u32, 1), para[4].cite_span.refs[1].num);
}

test "citations: duplicate refs in one mark register one backlink" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// refs citations()\n\n1. Only.\n\n//\n\n[x].cite(1,1)", .empty);
    const list = d.blocks[0].kind.group.sections[0][0].kind.list;
    try testing.expectEqual(@as(usize, 1), list.items[0].cite_sites.len);
}

test "citations: a key-only entry drops its emptied text node" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// refs citations()\n\n1. [k] *Styled.*\n\n//\n\n[x].cite(k)", .empty);
    const item = d.blocks[0].kind.group.sections[0][0].kind.list.items[0];
    // The `[k] ` prefix lifted; what remains starts with the emphasis, not
    // an empty text node.
    try testing.expect(item.text[0] == .em);
}

test "citations() absorbs a collapse() on the same opener with a warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// refs citations() collapse()\n\n1. Only.\n\n//\n\n[x].cite(1)", .empty);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "collapse ignored") != null);
    try testing.expect(d.blocks[0].attrs.citations);
    try testing.expectEqual(@as(?Collapse, null), d.blocks[0].attrs.collapse);
}

test "unterminated $$ reverts to a paragraph instead of swallowing the document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "$$\nx\n\nafter", .empty);
    try testing.expectEqual(@as(usize, 2), d.blocks.len);
    try testing.expect(d.blocks[0].kind == .paragraph);
    try testing.expect(d.blocks[1].kind == .paragraph);
}

test "multi-line $$ body carries no boundary newlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "$$\nE = mc^2\n$$", .empty);
    try testing.expectEqualStrings("E = mc^2", d.blocks[0].kind.math);
}

test "$$$ is not a display-math opener" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "$$$x\ny$$", .empty);
    try testing.expect(d.blocks[0].kind == .paragraph);
}

test "fence info string: tabs separate the language token too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "```zig\ttest\ncode\n```", .empty);
    try testing.expectEqualStrings("zig", d.blocks[0].kind.code.lang);
}

test "backtick runs match GFM: double backticks embed, unmatched stay literal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const embedded = try parseInlines(arena, "``a`b``");
    try testing.expectEqualStrings("a`b", embedded[0].code);
    const spaced = try parseInlines(arena, "`` ` ``");
    try testing.expectEqualStrings("`", spaced[0].code);
    // A run with no matching closer is literal text, never an empty span.
    const bare = try parseInlines(arena, "a `` b");
    try testing.expectEqualStrings("a `` b", bare[0].text);
}

test "mismatched group closer warns and stays prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// outer\n\nx\n\n// end other\n\n// end outer", .empty);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "mismatched closer") != null);
    const sections = d.blocks[0].kind.group.sections;
    try testing.expectEqual(@as(usize, 2), sections[0].len); // x + the prose closer
}

test "grid and indent arguments are range-capped" {
    try testing.expect(parseCommand("grid(12)") != null);
    try testing.expect(parseCommand("grid(13)") == null);
    try testing.expect(parseCommand("indent(8)") != null);
    try testing.expect(parseCommand("indent(9)") == null);
    try testing.expect(parseCommand("indent(18446744073709551615)") == null);
    try testing.expect(parseCommand("grid(99999999999999999999)") == null);
}

test "caption: position/split grammar, and malformed combos degrade" {
    // bare caption(): bottom, no split
    const bare = parseCommand("caption()").?.caption;
    try testing.expectEqual(CaptionPos.bottom, bare.pos);
    try testing.expect(bare.split_pct == null);
    // each position keyword; left/right get the default split, top/bottom none
    try testing.expectEqual(CaptionPos.top, parseCommand("caption(top)").?.caption.pos);
    try testing.expect(parseCommand("caption(top)").?.caption.split_pct == null);
    try testing.expectEqual(CaptionPos.bottom, parseCommand("caption(bottom)").?.caption.pos);
    const left = parseCommand("caption(left)").?.caption;
    try testing.expectEqual(CaptionPos.left, left.pos);
    try testing.expectEqual(@as(?usize, caption_default_split_pct), left.split_pct);
    const right = parseCommand("caption(right)").?.caption;
    try testing.expectEqual(CaptionPos.right, right.pos);
    try testing.expectEqual(@as(?usize, caption_default_split_pct), right.split_pct);
    // explicit split percent, with the spec's own spacing
    const explicit = parseCommand("caption(left, 45%)").?.caption;
    try testing.expectEqual(CaptionPos.left, explicit.pos);
    try testing.expectEqual(@as(?usize, 45), explicit.split_pct);
    try testing.expectEqual(@as(?usize, 45), parseCommand("caption(right,45%)").?.caption.split_pct);
    // malformed combos: whole directive degrades (parseCommand returns null)
    try testing.expect(parseCommand("caption(sideways)") == null);
    try testing.expect(parseCommand("caption(top, 30%)") == null);
    try testing.expect(parseCommand("caption(bottom, 30%)") == null);
    try testing.expect(parseCommand("caption(30%)") == null);
    try testing.expect(parseCommand("caption(left, 0%)") == null);
    try testing.expect(parseCommand("caption(left, 100%)") == null);
    try testing.expect(parseCommand("caption(left,)") == null);
    try testing.expect(parseCommand("caption(left, 30)") == null); // missing %
}

test "caption: opener-line tokenizer respects parens around a split's comma-space" {
    var p: Parser = .{ .arena = testing.allocator, .lines = &.{} };
    const gl = parseGroupLine(&p, "// caption(left, 30%) center()").?;
    try testing.expect(gl.open.attrs.caption_pos == .left);
    try testing.expectEqual(@as(?usize, 30), gl.open.attrs.caption_split_pct);
    try testing.expect(gl.open.attrs.centered);
}

test "caption: /caption(...) single-command form degrades to prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "/caption(bottom)\n\n![c](cat.png)", .empty);
    try testing.expect(d.blocks[0].kind == .paragraph); // "/caption(bottom)" stayed literal text
    try testing.expect(d.blocks[1].kind == .paragraph);
    try testing.expect(d.blocks[1].attrs.caption_pos == null);
}

test "caption: backward-attaches to its preceding sibling as section 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "![a panda](p.jpg)\n\n// caption()\nA panda, **2024**.\n// end", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const g = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 2), g.sections.len);
    try testing.expect(g.sections[0][0].kind == .paragraph); // popped partner (the image)
    try testing.expect(g.sections[1][0].kind == .paragraph); // caption body
    try testing.expect(d.blocks[0].attrs.caption_pos == .bottom);
}

test "caption: no preceding sibling warns and degrades to a plain group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// caption()\ntext\n// end", .empty);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "no preceding element") != null);
    const g = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 1), g.sections.len); // caption body only, no partner
}

test "caption: attaches within an enclosing group, not the top level" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// outer\n![a](a.jpg)\n\n// caption()\ncap\n// end\n// end outer", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    const outer_sections = d.blocks[0].kind.group.sections;
    try testing.expectEqual(@as(usize, 1), outer_sections[0].len); // just the caption group
    const inner = outer_sections[0][0].kind.group;
    try testing.expectEqual(@as(usize, 2), inner.sections.len);
}

test "caption: rich multi-block caption body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "![a](a.jpg)\n\n// caption()\nfirst **bold**\n\nsecond\n// end", .empty);
    const body = d.blocks[0].kind.group.sections[1];
    try testing.expectEqual(@as(usize, 2), body.len);
}

test "caption: chains with a sibling styling directive on the same opener" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "![a](a.jpg)\n\n// skinny(50%) caption(left, 40%)\ncap\n// end", .empty);
    const attrs = d.blocks[0].attrs;
    try testing.expectEqual(@as(?usize, 50), attrs.width_pct);
    try testing.expect(attrs.caption_pos == .left);
    try testing.expectEqual(@as(?usize, 40), attrs.caption_split_pct);
}

test "snug: bare grammar, args rejected" {
    try testing.expect(parseCommand("snug()").? == .snug);
    try testing.expect(parseCommand("snug(x)") == null);
    try testing.expect(parseCommand("snug(top)") == null);
}

test "snug: /snug() single-command form backward-attaches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "# Title\n\n/snug()\nA subtitle.", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const g = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 2), g.sections.len);
    try testing.expect(g.sections[0][0].kind == .heading); // popped partner (the title)
    try testing.expect(g.sections[1][0].kind == .paragraph); // snug body
    try testing.expect(d.blocks[0].attrs.snug);
}

test "snug: /snug() with no preceding sibling warns and degrades" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "/snug()\ntext", .empty);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "no preceding element") != null);
    const g = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 1), g.sections.len); // snug body only, no partner
}

test "snug: nested (non-root) in a /cmd() chain reverts that command to prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // `/color(accent)` can't wrap a nested `/snug()` — backward-attach only
    // works as a chain's outermost token — so its own chain aborts and the
    // line stays literal, uncolored prose. The freestanding `/snug()` that
    // follows is then parsed fresh and independently (and validly)
    // backward-attaches to that leftover prose paragraph, same as it would
    // to any other preceding block.
    const d = try parse(arena_state.allocator(), "/color(accent)\n/snug()\ntext", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const g = d.blocks[0].kind.group;
    const partner = g.sections[0][0];
    try testing.expect(partner.kind == .paragraph);
    try testing.expect(partner.attrs.text_color == null);
}

test "snug: /cmd() single-command form rejects arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "# Title\n\n/snug(x)\ntext", .empty);
    for (d.blocks) |b| try testing.expect(!b.attrs.snug);
}

test "snug: backward-attaches to its preceding sibling as section 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "# Title\n\n// snug()\nA subtitle.\n// end", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const g = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 2), g.sections.len);
    try testing.expect(g.sections[0][0].kind == .heading); // popped partner (the title)
    try testing.expect(g.sections[1][0].kind == .paragraph); // snug body
    try testing.expect(d.blocks[0].attrs.snug);
}

test "snug: no preceding sibling warns and degrades to a plain group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// snug()\ntext\n// end", .empty);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "no preceding element") != null);
    const g = d.blocks[0].kind.group;
    try testing.expectEqual(@as(usize, 1), g.sections.len); // snug body only, no partner
}

test "snug: attaches within an enclosing group, not the top level" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// outer\n# Title\n\n// snug()\nsub\n// end\n// end outer", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    const outer_sections = d.blocks[0].kind.group.sections;
    try testing.expectEqual(@as(usize, 1), outer_sections[0].len); // just the snug group
    const inner = outer_sections[0][0].kind.group;
    try testing.expectEqual(@as(usize, 2), inner.sections.len);
}

test "snug: chains with a sibling styling directive on the same opener" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "# Title\n\n// skinny(50%) snug()\nsub\n// end", .empty);
    const attrs = d.blocks[0].attrs;
    try testing.expectEqual(@as(?usize, 50), attrs.width_pct);
    try testing.expect(attrs.snug);
}

test "snug and caption together: whole opener degrades to prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d1 = try parse(arena_state.allocator(),
        "![a](a.jpg)\n\n// snug() caption()\n\ntext\n\n// end", .empty);
    try testing.expectEqual(@as(usize, 4), d1.blocks.len);
    try testing.expect(d1.blocks[1].kind == .paragraph); // opener line stayed literal
    try testing.expect(!d1.blocks[1].attrs.snug);
    try testing.expect(d1.blocks[1].attrs.caption_pos == null);

    const d2 = try parse(arena_state.allocator(),
        "![a](a.jpg)\n\n// caption() snug()\n\ntext\n\n// end", .empty);
    try testing.expect(d2.blocks[1].kind == .paragraph); // order-independent
}

test "empty postfix spans stay literal for color and cite alike" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const color = try parseInlines(arena, "[].color(accent)");
    try testing.expectEqualStrings("[].color(accent)", color[0].text);
    const cite = try parseInlines(arena, "[].cite(1)");
    try testing.expectEqualStrings("[].cite(1)", cite[0].text);
}

test "hasUrlBody checks the scheme by content" {
    try testing.expect(!hasUrlBody("https://"));
    try testing.expect(!hasUrlBody("http://"));
    try testing.expect(hasUrlBody("http://x"));
    try testing.expect(hasUrlBody("https://x"));
}

// ---- v0.1.0 test expansion ---------------------------------------------------

test "input edges: empty, whitespace-only, CRLF, no trailing newline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try parse(arena, "", .empty);
    try testing.expectEqual(@as(usize, 0), empty.blocks.len);
    const blank = try parse(arena, "  \n\t\n", .empty);
    try testing.expectEqual(@as(usize, 0), blank.blocks.len);
    const crlf = try parse(arena, "# T\r\n\r\nbody\r\n", .empty);
    try testing.expectEqualStrings("T", crlf.blocks[0].kind.heading.inlines[0].text);
    try testing.expectEqualStrings("body", crlf.blocks[1].kind.paragraph[0].text);
    const no_nl = try parse(arena, "last line", .empty);
    try testing.expectEqualStrings("last line", no_nl.blocks[0].kind.paragraph[0].text);
}

test "an unterminated fence runs to end of document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "```zig\ncode\nmore", .empty);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqualStrings("code\nmore\n", d.blocks[0].kind.code.text);
}

test "table rows pad and truncate to the header's column count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |", .empty);
    const t = d.blocks[0].kind.table;
    try testing.expectEqual(@as(usize, 2), t.header.len);
    try testing.expectEqual(@as(usize, 2), t.rows[0].len); // padded
    try testing.expectEqual(@as(usize, 2), t.rows[1].len); // truncated
    try testing.expectEqual(@as(usize, 0), t.rows[0][1].len); // the pad is empty
}

test "escaped pipes unescape in body rows too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "| h |\n|---|\n| a \\| b |", .empty);
    try testing.expectEqualStrings("a | b", d.blocks[0].kind.table.rows[0][0][0].text);
}

test "a nested > inside a quote stays literal text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "> outer\n> > inner", .empty);
    const q = d.blocks[0].kind.quote;
    // pinned: no nested-quote model — the inner `>` joins the flow as text
    try testing.expectEqual(@as(usize, 1), q.paras.len);
    try testing.expectEqualStrings("outer > inner", q.paras[0][0].text);
}

test "three list levels nest and dedent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "- a\n  - b\n    - c\n  - b2\n- a2", .empty);
    const l = d.blocks[0].kind.list;
    try testing.expectEqual(@as(usize, 2), l.items.len);
    const l2 = l.items[0].tail[0].list;
    try testing.expectEqual(@as(usize, 2), l2.items.len);
    const l3 = l2.items[0].tail[0].list;
    try testing.expectEqualStrings("c", l3.items[0].text[0].text);
    try testing.expectEqualStrings("b2", l2.items[1].text[0].text);
    try testing.expectEqualStrings("a2", l.items[1].text[0].text);
}

test "tab indentation nests a list (one tab = one level)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "- a\n\t- b", .empty);
    const l = d.blocks[0].kind.list;
    try testing.expectEqualStrings("b", l.items[0].tail[0].list.items[0].text[0].text);
}

test "text after a nested list lazily continues the deepest item" {
    // Pins the reason `Item.Tail.line` never occurs in practice: lazy
    // continuation is indent-agnostic, so a trailing line always joins the
    // innermost open item rather than falling back to the parent as a
    // `.line` segment. (The variant stays in the model for now — see the
    // v0.1.0 review notes.)
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "- a\n  - sub\n  trailing", .empty);
    const item = d.blocks[0].kind.list.items[0];
    try testing.expectEqual(@as(usize, 1), item.tail.len);
    const sub = item.tail[0].list.items[0];
    try testing.expectEqualStrings("sub trailing", sub.text[0].text);
}

test "citation marks resolve in every flowing context" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "# Head [h].cite(1)\n\n> Quote [q].cite(1)\n\n- Item [i].cite(1)\n\n| Cell [c].cite(1) |\n|---|\n\n// refs citations()\n\n1. Entry.\n\n//", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    const entry = d.blocks[4].kind.group.sections[0][0].kind.list.items[0];
    // all four marks registered backlinks
    try testing.expectEqual(@as(usize, 4), entry.cite_sites.len);
}

test "a citations() group nested inside a plain group still adopts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        "// outer\n\n// refs citations()\n\n1. Entry.\n\n// end refs\n\n// end outer\n\n[x].cite(1)", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    const para = d.blocks[1].kind.paragraph;
    try testing.expectEqual(@as(u32, 1), para[0].cite_span.refs[0].num);
}

test "key refs resolve regardless of document order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // the mark precedes the group; resolution runs at parse end
    const d = try parse(arena_state.allocator(),
        "Claim [x].cite(smith).\n\n// refs citations()\n\n1. [smith] Smith 2024.\n\n//", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(u32, 1), d.blocks[0].kind.paragraph[1].cite_span.refs[0].num);
}

// ---- aliases (docs/reference/design/010-aliases.md, candidate B) -------------

test "alias: an in-document definition applies through a group opener" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        ":thin-grid grid(2) skinny(80%)\n\n// figs thin-grid()\n\na\n\n// --\n\nb\n\n// end figs", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const g = d.blocks[0].kind.group;
    try testing.expectEqualStrings("figs", g.name);
    try testing.expectEqual(@as(usize, 2), d.blocks[0].attrs.columns.?);
    try testing.expectEqual(@as(usize, 80), d.blocks[0].attrs.width_pct.?);
    try testing.expectEqual(@as(usize, 2), g.sections.len);
}

test "alias: bundles several commands and composes with the opener's own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        ":muted-box color(muted) collapse()\n\n// muted-box() center()\n\na\n\n//", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    const attrs = d.blocks[0].attrs;
    try testing.expectEqual(TextColor.muted, attrs.text_color.?);
    try testing.expectEqual(Collapse.closed, attrs.collapse.?);
    try testing.expect(attrs.centered);
}

test "alias: usable as a bare first token with no separate group name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), ":wide-box wide()\n\n// wide-box()\n\na\n\n//", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqualStrings("", d.blocks[0].kind.group.name);
    try testing.expect(d.blocks[0].attrs.width_pct.? > 100);
}

test "alias: usable as a /alias() single-command directive, chains like a real command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), ":acc color(accent)\n\n/acc()\n/skinny(50%)\npara", .empty);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(TextColor.accent, d.blocks[0].attrs.text_color.?);
    const inner = d.blocks[0].kind.group.sections[0][0];
    try testing.expectEqual(@as(usize, 50), inner.attrs.width_pct.?);
}

test "alias: a use before its definition sees a plain name, not the alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // `thin-grid()` isn't defined yet at this point in the single-pass
    // parse — unrecognized, so the whole opener line degrades to prose.
    const d = try parse(arena_state.allocator(),
        "// figs thin-grid()\n\na\n\n// end figs\n\n:thin-grid grid(2)", .empty);
    try testing.expect(d.blocks[0].kind == .paragraph);
}

test "alias: the header sheet is in scope for the whole document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try sheet.fromSource(arena, ":thin-grid grid(2) skinny(80%)");
    const d = try parse(arena, "// figs thin-grid()\n\na\n\n// --\n\nb\n\n// end figs", base);
    try testing.expectEqual(@as(usize, 0), d.warnings.len);
    try testing.expectEqual(@as(usize, 2), d.blocks[0].attrs.columns.?);
}

test "alias: an in-document definition overrides the header sheet's same name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try sheet.fromSource(arena, ":thin-grid grid(2)");
    const d = try parse(arena, ":thin-grid grid(3)\n\n// thin-grid()\n\na\n\n//", base);
    try testing.expectEqual(@as(usize, 3), d.blocks[0].attrs.columns.?);
}

test "alias: caption-bundling degrades a /alias() single-command use to prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        ":cap caption(top)\n\n/cap()\n\n![c](cat.png)", .empty);
    try testing.expect(d.blocks[0].kind == .paragraph); // "/cap()" stayed literal text
}
