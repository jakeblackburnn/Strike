//! source text → `doc.Doc`. Pure: no I/O, no printing, allocates only from
//! the caller's arena. Everything observable about parsing is in the
//! returned `Doc` (see `dev/terms.md`, "Parse is pure").
//!
//! Two stages inside one function: a line-based **block loop** classifies
//! each line and consumes one block at a time, then flowing text (a
//! paragraph's gathered lines) runs through the **inline chain** once its
//! lines are joined. The block loop is recursive here: a `//` group opener
//! recurses into its own sections, so nesting is depth in the call stack
//! (capped — see `max_nesting`). See `dev/terms.md` for every term named
//! below and the rules behind them.

const std = @import("std");
const doc = @import("doc.zig");

const Allocator = std.mem.Allocator;

/// The layout-level nesting cap: a group opener at this depth or deeper
/// degrades to prose instead of opening (`dev/terms.md`, "degradation").
const max_nesting = 64;

pub fn parse(arena: Allocator, src: []const u8) !doc.Doc {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        // A trailing '\r' (CRLF input) is stripped per line.
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try lines.append(arena, line);
    }

    var warnings: std.ArrayList([]const u8) = .empty;
    var open_names: std.ArrayList([]const u8) = .empty;
    var warned_nesting = false;
    var i: usize = 0;
    const top = try parseSection(arena, lines.items, &i, &open_names, &warnings, &warned_nesting);

    return .{ .blocks = top.blocks, .warnings = warnings.items };
}

const StopReason = enum {
    /// End of document.
    eof,
    /// A `===` line ended this section; the caller starts the next one.
    split,
    /// A closer matching the innermost open group's name ended this
    /// section; the caller finalizes the group.
    closer,
};

const Section = struct { blocks: []doc.Block, reason: StopReason };

/// Parses blocks until end-of-document, or — when `open_names` is
/// non-empty, i.e. this call is gathering one section of an open group —
/// until a `===` or a closer matching the innermost name. Neither
/// terminator line is consumed; the caller (the group-opening arm below)
/// does that, so it can tell a section split from a group close.
fn parseSection(
    arena: Allocator,
    lines: []const []const u8,
    i: *usize,
    open_names: *std.ArrayList([]const u8),
    warnings: *std.ArrayList([]const u8),
    warned_nesting: *bool,
) !Section {
    var blocks: std.ArrayList(doc.Block) = .empty;
    while (i.* < lines.len) {
        const line = lines[i.*];
        if (isBlank(line)) {
            i.* += 1;
            continue;
        }

        if (open_names.items.len > 0) {
            if (isSectionSplit(line)) return .{ .blocks = blocks.items, .reason = .split };
            if (groupEnd(line)) |name| {
                const innermost = open_names.items[open_names.items.len - 1];
                if (std.mem.eql(u8, name, innermost)) {
                    return .{ .blocks = blocks.items, .reason = .closer };
                }
                // A closer naming a group that isn't the innermost open one
                // is prose (degradation) — fall through to paragraph
                // gathering below, same as any other content line.
                try warnings.append(arena, try std.fmt.allocPrint(
                    arena,
                    "group '{s}': mismatched closer '// end {s}' treated as prose",
                    .{ innermost, name },
                ));
            }
        }

        if (headingLevel(line)) |level| {
            const text = std.mem.trim(u8, line[level + 1 ..], " \t");
            try blocks.append(arena, .{ .heading = .{
                .level = level,
                .inlines = try parseInlines(arena, text),
            } });
            i.* += 1;
            continue;
        }
        if (fenceLang(line)) |lang| {
            i.* += 1;
            var body: std.ArrayList(u8) = .empty;
            while (i.* < lines.len and !isFenceEnd(lines[i.*])) {
                try body.appendSlice(arena, lines[i.*]);
                try body.append(arena, '\n');
                i.* += 1;
            }
            if (i.* < lines.len) i.* += 1; // consume closing fence
            try blocks.append(arena, .{ .code = .{ .lang = lang, .text = body.items } });
            continue;
        }

        if (open_names.items.len < max_nesting) {
            if (groupOpen(line)) |name| {
                i.* += 1; // consume opener
                try open_names.append(arena, name);
                var sections: std.ArrayList([]doc.Block) = .empty;
                while (true) {
                    const sub = try parseSection(arena, lines, i, open_names, warnings, warned_nesting);
                    try sections.append(arena, sub.blocks);
                    switch (sub.reason) {
                        .split => i.* += 1, // consume "===", gather the next section
                        .closer => {
                            i.* += 1; // consume "// end name"
                            break;
                        },
                        .eof => {
                            try warnings.append(arena, try std.fmt.allocPrint(
                                arena,
                                "unclosed group '{s}' (ran to end of document)",
                                .{name},
                            ));
                            break;
                        },
                    }
                }
                _ = open_names.pop();
                try blocks.append(arena, .{ .group = .{ .name = name, .sections = sections.items } });
                continue;
            }
        } else if (groupOpen(line) != null and !warned_nesting.*) {
            warned_nesting.* = true;
            try warnings.append(arena, "nesting deeper than 64 levels; deeper structure flattens to prose");
        }

        // Paragraph: gather consecutive lines that don't interrupt flow,
        // join with a space (soft-wrap), and inline-parse once. This is
        // flow-joining — see `dev/terms.md`.
        var raw_lines: std.ArrayList([]const u8) = .empty;
        while (i.* < lines.len and !isBlank(lines[i.*]) and !interruptsFlow(lines[i.*], open_names.items)) {
            try raw_lines.append(arena, lines[i.*]);
            i.* += 1;
        }
        const joined = try std.mem.join(arena, " ", raw_lines.items);
        try blocks.append(arena, .{ .paragraph = try parseInlines(arena, joined) });
    }
    return .{ .blocks = blocks.items, .reason = .eof };
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// The one shared "does this line break a flowing text run" check — the
/// `isBlockStart` companion rule extended to the group directives, which
/// need context (`open_names`) an isolated per-line check can't have:
/// `===` and a closer only mean something inside an open group, and a
/// closer only interrupts when it matches the *innermost* name (a mismatch
/// is prose, so it must NOT interrupt — it just continues the paragraph).
fn interruptsFlow(line: []const u8, open_names: []const []const u8) bool {
    if (headingLevel(line) != null or fenceLang(line) != null) return true;
    if (open_names.len < max_nesting and groupOpen(line) != null) return true;
    if (open_names.len > 0) {
        if (isSectionSplit(line)) return true;
        if (groupEnd(line)) |name| {
            if (std.mem.eql(u8, name, open_names[open_names.len - 1])) return true;
        }
    }
    return false;
}

/// 1..6 for a valid ATX heading opener (`#` through `######` followed by a
/// space), else null.
fn headingLevel(line: []const u8) ?u8 {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return level;
}

/// The fence opener's info-string language (first whitespace-delimited
/// token, "" if none), or null if `line` isn't a fence opener.
fn fenceLang(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "```")) return null;
    const rest = std.mem.trim(u8, line[3..], " \t");
    var tok = std.mem.tokenizeAny(u8, rest, " \t");
    return tok.next() orelse "";
}

fn isFenceEnd(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "```");
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// A `//` line is a group directive **iff it parses cleanly** — this is
/// the degradation rule (`dev/terms.md`): `// TODO: fix` has a space and a
/// colon in it, fails the identifier check below, and stays a plain
/// paragraph line, exactly like it would in any markdown viewer.
fn groupOpen(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "//")) return null;
    const rest = std.mem.trim(u8, line[2..], " \t");
    if (rest.len == 0 or std.mem.eql(u8, rest, "end")) return null;
    for (rest) |c| if (!isIdentChar(c)) return null;
    return rest;
}

/// `// end <name>`, name-only, else null.
fn groupEnd(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "//")) return null;
    const rest = std.mem.trim(u8, line[2..], " \t");
    if (!std.mem.startsWith(u8, rest, "end")) return null;
    if (rest.len == 3 or (rest[3] != ' ' and rest[3] != '\t')) return null;
    const name = std.mem.trim(u8, rest[3..], " \t");
    if (name.len == 0) return null;
    for (name) |c| if (!isIdentChar(c)) return null;
    return name;
}

fn isSectionSplit(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "===");
}

// ---- inline chain ------------------------------------------------------------

/// Parses one already-flow-joined string into inlines, left to right, one
/// pass. Arms tried in precedence order at each position: `` `code` ``,
/// then `**strong**`, then `*em*`. No flanking rules yet (backlog,
/// `dev/terms.md`) — a delimiter simply pairs with the next matching one it
/// finds. Code spans are never inline-parsed further; strong/em bodies are,
/// recursively, so they can nest.
fn parseInlines(arena: Allocator, text: []const u8) ![]doc.Inline {
    var out: std.ArrayList(doc.Inline) = .empty;
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                try flushText(arena, &out, text[plain_start..i]);
                try out.append(arena, .{ .code = text[i + 1 .. close] });
                i = close + 1;
                plain_start = i;
                continue;
            }
        } else if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |close| {
                try flushText(arena, &out, text[plain_start..i]);
                const inner = try parseInlines(arena, text[i + 2 .. close]);
                try out.append(arena, .{ .strong = inner });
                i = close + 2;
                plain_start = i;
                continue;
            }
        } else if (c == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |close| {
                try flushText(arena, &out, text[plain_start..i]);
                const inner = try parseInlines(arena, text[i + 1 .. close]);
                try out.append(arena, .{ .em = inner });
                i = close + 1;
                plain_start = i;
                continue;
            }
        }
        i += 1;
    }
    try flushText(arena, &out, text[plain_start..]);
    return out.items;
}

fn flushText(arena: Allocator, out: *std.ArrayList(doc.Inline), s: []const u8) !void {
    if (s.len == 0) return;
    try out.append(arena, .{ .text = s });
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

test "heading" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "## Hello *there*");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const h = d.blocks[0].heading;
    try testing.expectEqual(@as(u8, 2), h.level);
    try testing.expectEqual(@as(usize, 2), h.inlines.len);
    try testing.expectEqualStrings("Hello ", h.inlines[0].text);
    try testing.expectEqualStrings("there", h.inlines[1].em[0].text);
}

test "paragraph joins soft-wrapped lines with a space" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "one\ntwo");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqualStrings("one two", d.blocks[0].paragraph[0].text);
}

test "a blank line separates paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "one\n\ntwo");
    try testing.expectEqual(@as(usize, 2), d.blocks.len);
}

test "fenced code is verbatim, never inline-parsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "```zig\nconst *x* = 1;\n```");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const code = d.blocks[0].code;
    try testing.expectEqualStrings("zig", code.lang);
    try testing.expectEqualStrings("const *x* = 1;\n", code.text);
}

test "an unterminated fence runs to end-of-document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "```\nabc");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqualStrings("abc\n", d.blocks[0].code.text);
}

test "isBlockStart companion: a heading after a paragraph is not swallowed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "some text\n# Heading");
    try testing.expectEqual(@as(usize, 2), d.blocks.len);
    try testing.expectEqualStrings("some text", d.blocks[0].paragraph[0].text);
    try testing.expectEqual(@as(u8, 1), d.blocks[1].heading.level);
}

test "isBlockStart companion: a fence after a paragraph is not swallowed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "some text\n```\ncode\n```");
    try testing.expectEqual(@as(usize, 2), d.blocks.len);
}

test "inline code span" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "use `x` here");
    const p = d.blocks[0].paragraph;
    try testing.expectEqual(@as(usize, 3), p.len);
    try testing.expectEqualStrings("x", p[1].code);
}

test "strong and em nest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "**bold *and* text**");
    const p = d.blocks[0].paragraph;
    try testing.expectEqual(@as(usize, 1), p.len);
    const strong = p[0].strong;
    try testing.expectEqual(@as(usize, 3), strong.len);
    try testing.expectEqualStrings("and", strong[1].em[0].text);
}

test "a span may open on one soft-wrapped line and close on the next" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "*asdf\nqwer*");
    const p = d.blocks[0].paragraph;
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expectEqualStrings("asdf qwer", p[0].em[0].text);
}

test "a group opens, holds content, and closes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// aside\n\nhello\n\n// end aside");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const g = d.blocks[0].group;
    try testing.expectEqualStrings("aside", g.name);
    try testing.expectEqual(@as(usize, 1), g.sections.len);
    try testing.expectEqualStrings("hello", g.sections[0][0].paragraph[0].text);
}

test "=== splits a group into sections" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// two\n\na\n\n===\n\nb\n\n// end two");
    const g = d.blocks[0].group;
    try testing.expectEqual(@as(usize, 2), g.sections.len);
    try testing.expectEqualStrings("a", g.sections[0][0].paragraph[0].text);
    try testing.expectEqualStrings("b", g.sections[1][0].paragraph[0].text);
}

test "groups nest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// outer\n\n// inner\n\nx\n\n// end inner\n\n// end outer");
    const outer = d.blocks[0].group;
    try testing.expectEqualStrings("outer", outer.name);
    const inner = outer.sections[0][0].group;
    try testing.expectEqualStrings("inner", inner.name);
    try testing.expectEqualStrings("x", inner.sections[0][0].paragraph[0].text);
}

test "degradation: an unrecognized // line is inert prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// TODO: fix this");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqualStrings("// TODO: fix this", d.blocks[0].paragraph[0].text);
}

test "degradation: === outside any group is inert prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "===");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqualStrings("===", d.blocks[0].paragraph[0].text);
}

test "a closer naming a group that isn't the innermost open one is prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// aside\n\n// end other\n\n// end aside");
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    const g = d.blocks[0].group;
    try testing.expectEqualStrings("// end other", g.sections[0][0].paragraph[0].text);
}

test "an unclosed group runs to end-of-document, with a warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "// aside\n\nhello");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    try testing.expectEqual(@as(usize, 1), d.warnings.len);
    try testing.expect(std.mem.indexOf(u8, d.warnings[0], "unclosed group 'aside'") != null);
}
