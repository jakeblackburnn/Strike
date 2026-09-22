//! source text → `doc.Doc`. Pure: no I/O, no printing, allocates only from
//! the caller's arena. Everything observable about parsing is in the
//! returned `Doc` (see `dev/terms.md`, "Parse is pure").
//!
//! Two stages inside one function: a line-based **block loop** classifies
//! each line and consumes one block at a time, then flowing text (a
//! paragraph's gathered lines) runs through the **inline chain** once its
//! lines are joined. See `dev/terms.md` for both terms and the rules named
//! below.

const std = @import("std");
const doc = @import("doc.zig");

const Allocator = std.mem.Allocator;

pub fn parse(arena: Allocator, src: []const u8) !doc.Doc {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        // A trailing '\r' (CRLF input) is stripped per line.
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try lines.append(arena, line);
    }

    var blocks: std.ArrayList(doc.Block) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (isBlank(line)) {
            i += 1;
            continue;
        }
        if (headingLevel(line)) |level| {
            const text = std.mem.trim(u8, line[level + 1 ..], " \t");
            try blocks.append(arena, .{ .heading = .{
                .level = level,
                .inlines = try parseInlines(arena, text),
            } });
            i += 1;
            continue;
        }
        if (fenceLang(line)) |lang| {
            i += 1;
            var body: std.ArrayList(u8) = .empty;
            while (i < lines.items.len and !isFenceEnd(lines.items[i])) {
                try body.appendSlice(arena, lines.items[i]);
                try body.append(arena, '\n');
                i += 1;
            }
            // An unterminated fence runs to end-of-document (i == lines.items.len);
            // otherwise consume the closing fence line.
            if (i < lines.items.len) i += 1;
            try blocks.append(arena, .{ .code = .{ .lang = lang, .text = body.items } });
            continue;
        }

        // Paragraph: gather consecutive lines that don't start a new block,
        // join them with a space (soft-wrap), and inline-parse the joined
        // text once. This is flow-joining — see `dev/terms.md`.
        var raw_lines: std.ArrayList([]const u8) = .empty;
        while (i < lines.items.len and !isBlank(lines.items[i]) and !isBlockStart(lines.items[i])) {
            try raw_lines.append(arena, lines.items[i]);
            i += 1;
        }
        const joined = try std.mem.join(arena, " ", raw_lines.items);
        try blocks.append(arena, .{ .paragraph = try parseInlines(arena, joined) });
    }

    return .{ .blocks = blocks.items };
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// The `isBlockStart` companion rule: every block form needs an arm here,
/// or a preceding paragraph swallows its first line as a soft-wrap
/// continuation instead of starting a new block. See `dev/terms.md`.
fn isBlockStart(line: []const u8) bool {
    return headingLevel(line) != null or fenceLang(line) != null;
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
