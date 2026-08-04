//! A deliberately tiny YAML-subset parser — just enough to drive `strike.yaml`.
//!
//! `strikedown` takes no build/runtime dependencies (CLAUDE.md), so rather than
//! pull in a YAML library this parses a strict, documented subset by hand:
//!
//!   - `# comments` (whole-line or trailing) and blank lines (ignored)
//!   - `key: value` scalars; values may be bare, `"double"`- or `'single'`-quoted
//!   - nested maps via indentation (2 spaces per level by convention, any
//!     consistent amount works — children just need a deeper indent than parent)
//!   - block sequences: `- item` of scalars *and* of maps (`- key: value` plus
//!     deeper-aligned keys)
//!
//! Explicitly NOT supported: flow collections (`[a, b]`, `{a: b}`), anchors and
//! aliases (`&`/`*`), block scalars (`|`, `>`), tags (`!!str`), multi-document
//! streams (`---`). Anything unrecognised is skipped rather than fatal — callers
//! treat a parse failure as "use defaults", so this never takes the server down.
//!
//! The parser is pure (allocator in, owned tree out) and unit-tested below.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A parsed YAML node. Scalars/keys are duped into the parse allocator, so the
/// tree outlives the source text. Use an arena and free it all at once.
pub const Value = union(enum) {
    scalar: []const u8,
    list: []Value,
    map: []Pair,

    pub const Pair = struct { key: []const u8, value: Value };

    /// Look up `key` in a map value; null for non-maps or missing keys.
    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .map => |pairs| for (pairs) |p| {
                if (std.mem.eql(u8, p.key, key)) return p.value;
            },
            else => {},
        }
        return null;
    }

    /// `get` restricted to scalar values (the common case).
    pub fn getScalar(self: Value, key: []const u8) ?[]const u8 {
        if (self.get(key)) |v| switch (v) {
            .scalar => |s| return s,
            else => {},
        };
        return null;
    }

    /// `get` restricted to list values.
    pub fn getList(self: Value, key: []const u8) ?[]const Value {
        if (self.get(key)) |v| switch (v) {
            .list => |l| return l,
            else => {},
        };
        return null;
    }
};

/// One significant (non-blank, non-comment) source line.
const Line = struct { indent: usize, content: []const u8 };

const Parser = struct {
    gpa: Allocator,
    lines: []Line,
    i: usize = 0,

    fn peek(p: *Parser) ?Line {
        return if (p.i < p.lines.len) p.lines[p.i] else null;
    }

    /// Parse the block (map or sequence) whose lines all share `indent`.
    fn parseBlock(p: *Parser, indent: usize) Allocator.Error!Value {
        const first = p.peek() orelse return .{ .scalar = "" };
        if (isItem(first.content)) return p.parseList(indent);
        return p.parseMap(indent);
    }

    fn parseMap(p: *Parser, indent: usize) Allocator.Error!Value {
        var pairs: std.ArrayList(Value.Pair) = .empty;
        while (p.peek()) |line| {
            if (line.indent != indent or isItem(line.content)) break;
            const colon = keyColon(line.content) orelse break;
            const key = try p.dupeScalar(std.mem.trim(u8, line.content[0..colon], " \t"));
            const rest = std.mem.trim(u8, line.content[colon + 1 ..], " \t");
            p.i += 1;
            var value: Value = undefined;
            if (rest.len > 0) {
                value = .{ .scalar = try p.dupeScalar(rest) };
            } else if (p.peek()) |next| {
                if (next.indent > indent) {
                    value = try p.parseBlock(next.indent);
                } else value = .{ .scalar = "" };
            } else value = .{ .scalar = "" };
            try pairs.append(p.gpa, .{ .key = key, .value = value });
        }
        return .{ .map = try pairs.toOwnedSlice(p.gpa) };
    }

    fn parseList(p: *Parser, indent: usize) Allocator.Error!Value {
        var items: std.ArrayList(Value) = .empty;
        while (p.peek()) |line| {
            if (line.indent != indent or !isItem(line.content)) break;
            const rest = std.mem.trim(u8, line.content[1..], " \t");
            if (rest.len == 0) {
                // `-` on its own: the item is the nested block below it.
                p.i += 1;
                if (p.peek()) |next| {
                    if (next.indent > indent) {
                        try items.append(p.gpa, try p.parseBlock(next.indent));
                        continue;
                    }
                }
                try items.append(p.gpa, .{ .scalar = "" });
            } else if (keyColon(rest) != null) {
                // `- key: value`: a map item. Re-anchor this line at the
                // key's true column, then absorb continuation keys wherever
                // the author aligned them (`parseItemMap`) — fail-soft means
                // no plausible alignment silently drops the list's tail.
                const key_col = indent + 1 + leftSpace(line.content[1..]);
                p.lines[p.i] = .{ .indent = key_col, .content = rest };
                try items.append(p.gpa, try p.parseItemMap(indent));
            } else {
                p.i += 1;
                try items.append(p.gpa, .{ .scalar = try p.dupeScalar(rest) });
            }
        }
        return .{ .list = try items.toOwnedSlice(p.gpa) };
    }

    /// A list item's map (`- key: value` plus continuation keys): keys sit at
    /// *any* column deeper than the dash — authors space the dash and align
    /// continuations by eye (`-   slug: x` with `name:` under either the
    /// dash-plus-two or the key itself), and every plausible alignment should
    /// parse rather than silently terminating the list. Nested blocks under
    /// an empty-valued key still recurse on that key's own column.
    fn parseItemMap(p: *Parser, list_indent: usize) Allocator.Error!Value {
        var pairs: std.ArrayList(Value.Pair) = .empty;
        while (p.peek()) |line| {
            if (line.indent <= list_indent or isItem(line.content)) break;
            const colon = keyColon(line.content) orelse break;
            const key = try p.dupeScalar(std.mem.trim(u8, line.content[0..colon], " \t"));
            const rest = std.mem.trim(u8, line.content[colon + 1 ..], " \t");
            const key_indent = line.indent;
            p.i += 1;
            var value: Value = undefined;
            if (rest.len > 0) {
                value = .{ .scalar = try p.dupeScalar(rest) };
            } else if (p.peek()) |next| {
                if (next.indent > key_indent) {
                    value = try p.parseBlock(next.indent);
                } else value = .{ .scalar = "" };
            } else value = .{ .scalar = "" };
            try pairs.append(p.gpa, .{ .key = key, .value = value });
        }
        return .{ .map = try pairs.toOwnedSlice(p.gpa) };
    }

    /// Strip one pair of matching surrounding quotes, then dupe into the arena.
    fn dupeScalar(p: *Parser, s: []const u8) Allocator.Error![]const u8 {
        var t = s;
        if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) {
            t = t[1 .. t.len - 1];
        }
        return p.gpa.dupe(u8, t);
    }
};

/// Parse `src` into a `Value`. On a structurally empty document returns an empty
/// map. The returned tree is owned by `gpa` (use an arena to free in one shot).
pub fn parse(gpa: Allocator, src: []const u8) Allocator.Error!Value {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const stripped = stripComment(raw);
        const indent = leftSpace(stripped);
        const content = std.mem.trimEnd(u8, stripped[indent..], " \t\r");
        if (content.len == 0) continue;
        try lines.append(gpa, .{ .indent = indent, .content = content });
    }

    if (lines.items.len == 0) return .{ .map = &.{} };
    var p: Parser = .{ .gpa = gpa, .lines = lines.items };
    return p.parseBlock(lines.items[0].indent);
}

/// Count leading ASCII spaces (indentation; tabs are not indentation in YAML).
fn leftSpace(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') n += 1;
    return n;
}

/// A left-trimmed line is a sequence item if it is `-` or starts with `- `.
fn isItem(content: []const u8) bool {
    return std.mem.eql(u8, content, "-") or std.mem.startsWith(u8, content, "- ");
}

/// Remove a trailing/whole-line `#` comment, respecting quoted spans. A `#`
/// only starts a comment at line start or after whitespace (so `#fff` colors and
/// `http://…#frag` survive when unquoted-adjacent). A quote only *opens* at a
/// word boundary — the apostrophe in `Jack's notes  # x` is prose, not a
/// quote that would swallow the comment marker.
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if ((c == '"' or c == '\'') and
            (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t'))
        {
            quote = c;
        } else if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return line[0..i];
        }
    }
    return line;
}

/// The index of the key/value `:` — the first colon *outside* a quoted span,
/// so `"a:b": v` keys as `a:b` and `- "a: b"` is a scalar item, not a map.
fn keyColon(content: []const u8) ?usize {
    var quote: u8 = 0;
    for (content, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == ':') return i;
    }
    return null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "scalars, quotes, and comments" {
    const src =
        \\# leading comment
        \\title: strikedown
        \\repo: "https://github.com/you/strike"   # trailing comment
        \\accent: '#2563eb'
        \\theme: dark
    ;
    const v = try parse(testing.allocator, src);
    defer free(testing.allocator, v);
    try testing.expectEqualStrings("strikedown", v.getScalar("title").?);
    try testing.expectEqualStrings("https://github.com/you/strike", v.getScalar("repo").?);
    try testing.expectEqualStrings("#2563eb", v.getScalar("accent").?);
    try testing.expectEqualStrings("dark", v.getScalar("theme").?);
}

test "nested map" {
    const src =
        \\labels:
        \\  01_probability_statistics.md: Probability & Statistics
        \\  topo: Topology
        \\  topo/algo_ref: Algorithm Reference
    ;
    const v = try parse(testing.allocator, src);
    defer free(testing.allocator, v);
    const labels = v.get("labels").?;
    try testing.expectEqualStrings("Probability & Statistics", labels.getScalar("01_probability_statistics.md").?);
    try testing.expectEqualStrings("Topology", labels.getScalar("topo").?);
    try testing.expectEqualStrings("Algorithm Reference", labels.getScalar("topo/algo_ref").?);
}

test "scalar sequence" {
    const src =
        \\order:
        \\  - 01_probability_statistics.md
        \\  - 02_distance_similarity.md
        \\  - topo
        \\hidden:
        \\  - PRACTICE_EXAM.md
    ;
    const v = try parse(testing.allocator, src);
    defer free(testing.allocator, v);
    const order = v.getList("order").?;
    try testing.expectEqual(@as(usize, 3), order.len);
    try testing.expectEqualStrings("01_probability_statistics.md", order[0].scalar);
    try testing.expectEqualStrings("topo", order[2].scalar);
    try testing.expectEqualStrings("PRACTICE_EXAM.md", v.getList("hidden").?[0].scalar);
}

test "sequence of maps" {
    const src =
        \\projects:
        \\  - slug: data_mining
        \\    title: Data Mining
        \\  - slug: pchem
        \\    title: Physical Chemistry
    ;
    const v = try parse(testing.allocator, src);
    defer free(testing.allocator, v);
    const projects = v.getList("projects").?;
    try testing.expectEqual(@as(usize, 2), projects.len);
    try testing.expectEqualStrings("data_mining", projects[0].getScalar("slug").?);
    try testing.expectEqualStrings("Physical Chemistry", projects[1].getScalar("title").?);
}

test "empty and missing" {
    const v = try parse(testing.allocator, "# only a comment\n\n");
    defer free(testing.allocator, v);
    try testing.expect(v.getScalar("nope") == null);
    try testing.expect(v.getList("nope") == null);
}

test "malformed: duplicate keys both parse; get returns the first" {
    const v = try parse(testing.allocator, "title: first\ntitle: second\n");
    defer free(testing.allocator, v);
    try testing.expectEqualStrings("first", v.getScalar("title").?);
    try testing.expectEqual(@as(usize, 2), v.map.len);
}

test "malformed: tabs are not indentation — a tab-indented child reads as top level" {
    const v = try parse(testing.allocator, "serve:\n\tport: 9000\n");
    defer free(testing.allocator, v);
    // `port` never nests under `serve` (leftSpace counts spaces only); the
    // tab is trimmed from the key, so it surfaces as a sibling.
    try testing.expectEqualStrings("", v.getScalar("serve").?);
    try testing.expectEqualStrings("9000", v.getScalar("port").?);
}

test "malformed: fail-soft truncation, never an error" {
    // A stray deeper line after a scalar value is dropped, and a colon-less
    // line stops the current map — everything after it is skipped.
    const v1 = try parse(testing.allocator, "a: 1\n  b: 2\n");
    defer free(testing.allocator, v1);
    try testing.expectEqualStrings("1", v1.getScalar("a").?);
    try testing.expect(v1.get("b") == null);

    const v2 = try parse(testing.allocator, "a: 1\njunk line\nb: 2\n");
    defer free(testing.allocator, v2);
    try testing.expectEqualStrings("1", v2.getScalar("a").?);
    try testing.expect(v2.get("b") == null);
}

test "malformed: a sequence under a scalar value is dropped" {
    const v = try parse(testing.allocator, "key: val\n  - x\n");
    defer free(testing.allocator, v);
    try testing.expectEqualStrings("val", v.getScalar("key").?);
    try testing.expect(v.getList("key") == null);
}

/// Recursively free a tree allocated by `parse` (test helper; production code
/// uses an arena instead).
fn free(gpa: Allocator, v: Value) void {
    switch (v) {
        .scalar => |s| gpa.free(s),
        .list => |l| {
            for (l) |item| free(gpa, item);
            gpa.free(l);
        },
        .map => |pairs| {
            for (pairs) |p| {
                gpa.free(p.key);
                free(gpa, p.value);
            }
            gpa.free(pairs);
        },
    }
}

test "an apostrophe in an unquoted value doesn't swallow the comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "title: Jack's notes  # the site title");
    try testing.expectEqualStrings("Jack's notes", v.getScalar("title").?);
}

test "quoted keys and values keep their colons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "\"a:b\": v\nplain: w");
    try testing.expectEqualStrings("v", v.getScalar("a:b").?);
    try testing.expectEqualStrings("w", v.getScalar("plain").?);
    // a quoted list item with a colon is a scalar, not a map
    const l = try parse(arena.allocator(), "items:\n  - \"a: b\"\n  - c");
    const items = l.get("items").?.list;
    try testing.expectEqualStrings("a: b", items[0].scalar);
    try testing.expectEqualStrings("c", items[1].scalar);
}

test "over-spaced sequence dashes keep conventional continuation keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\projects:
        \\  -   slug: a
        \\      name: x
        \\  - slug: b
    );
    const items = v.get("projects").?.list;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a", items[0].getScalar("slug").?);
    try testing.expectEqualStrings("b", items[1].getScalar("slug").?);
}
