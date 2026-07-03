//! Typography sheets: the strikedown *directive* syntax and the `Sheet` it
//! builds up.
//!
//! A directive is a block-position line starting with `:`:
//!
//!   :color brand #7c3aed
//!
//! Directives appear in two places, parsed by the same `parseLine`:
//!   - **in a document**, where the strikedown parser consumes them (they emit
//!     no block) and they extend the document's working sheet from that line on
//!   - **in a `.sxh` header file** — a shared collection of directives that
//!     `strike.yaml` attaches to a whole site/project via `header:` (see
//!     `project.zig`), seeding every document's working sheet
//!
//! Today the only directive is `:color <name> <value>`, defining a color alias
//! that a `(name)` block prefix applies (see `strikedown.zig`). Future
//! directives (`:margin`, `:block h1 …`, …) grow the `Directive` union and the
//! `Sheet` fields here, an attribute on the tree node they style, and the
//! emitter arm that reads it — never an emitter special case keyed on content.
//!
//! Fail-soft, like `yaml.zig`: a line that doesn't parse as a known directive
//! is simply not a directive (in a document it stays prose; in a `.sxh` it is
//! skipped), and a missing/unreadable header file is the caller's problem to
//! degrade gracefully.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An immutable bundle of typography settings. Sheets layer by concatenation
/// (site header, then project header, then in-document directives); `lookup`
/// scans backwards so the *last* definition of a name wins.
pub const Sheet = struct {
    colors: []const Entry = &.{},

    pub const Entry = struct { name: []const u8, value: []const u8 };
    pub const empty: Sheet = .{};

    /// Resolve a color alias to its value; null if the name is undefined
    /// (which makes a `(name)` prefix stay literal prose).
    pub fn lookup(self: Sheet, name: []const u8) ?[]const u8 {
        var i = self.colors.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.colors[i].name, name)) return self.colors[i].value;
        }
        return null;
    }
};

pub const Directive = union(enum) {
    color: Sheet.Entry,
};

/// Parse one (left-trimmed) line as a directive, or null if it isn't one.
/// `:color <name> <value>` — exactly three tokens, alias-safe name. Unknown
/// keywords and malformed lines return null (fail-soft: prose, not an error).
pub fn parseLine(line: []const u8) ?Directive {
    if (line.len < 2 or line[0] != ':') return null;
    var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const keyword = it.next() orelse return null;
    if (std.mem.eql(u8, keyword, "color")) {
        const name = it.next() orelse return null;
        const value = it.next() orelse return null;
        if (it.next() != null) return null;
        if (!isAliasName(name)) return null;
        return .{ .color = .{ .name = name, .value = value } };
    }
    return null;
}

/// Alias names are `[A-Za-z0-9_-]+` — what a `(name)` block prefix accepts.
pub fn isAliasName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// Load a `.sxh` header file from `dir` into a `Sheet`: every directive line
/// collected in order, everything else ignored. The sheet's strings live in
/// `arena` (they slice the file buffer read into it). I/O errors propagate —
/// the caller decides how to degrade.
pub fn load(io: std.Io, arena: Allocator, dir: std.Io.Dir, path: []const u8) !Sheet {
    const src = try dir.readFileAlloc(io, path, arena, .limited(1 << 20));
    return fromSource(arena, src);
}

/// Collect a sheet from directive source text (the pure core of `load`).
pub fn fromSource(arena: Allocator, src: []const u8) Allocator.Error!Sheet {
    var colors: std.ArrayList(Sheet.Entry) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const directive = parseLine(line) orelse continue;
        switch (directive) {
            .color => |entry| try colors.append(arena, entry),
        }
    }
    return .{ .colors = try colors.toOwnedSlice(arena) };
}

/// Layer `over` on top of `base` into one sheet (later entries win in
/// `lookup`). Used to stack the project header over the site header.
pub fn concat(arena: Allocator, base: Sheet, over: Sheet) Allocator.Error!Sheet {
    if (base.colors.len == 0) return over;
    if (over.colors.len == 0) return base;
    const colors = try arena.alloc(Sheet.Entry, base.colors.len + over.colors.len);
    @memcpy(colors[0..base.colors.len], base.colors);
    @memcpy(colors[base.colors.len..], over.colors);
    return .{ .colors = colors };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "parseLine accepts :color and rejects everything else" {
    const d = parseLine(":color brand #7c3aed").?;
    try testing.expectEqualStrings("brand", d.color.name);
    try testing.expectEqualStrings("#7c3aed", d.color.value);
    // extra spacing between tokens is fine
    try testing.expect(parseLine(":color  white  #FFFFFF") != null);

    try testing.expect(parseLine("plain prose") == null);
    try testing.expect(parseLine(":margin 2rem") == null); // unknown keyword
    try testing.expect(parseLine(":color onlyname") == null); // missing value
    try testing.expect(parseLine(":color a b c") == null); // trailing junk
    try testing.expect(parseLine(":color b@d #fff") == null); // bad alias name
    try testing.expect(parseLine(":") == null);
}

test "Sheet.lookup: last definition wins, unknown is null" {
    const sheet: Sheet = .{ .colors = &.{
        .{ .name = "brand", .value = "#111111" },
        .{ .name = "brand", .value = "#222222" },
    } };
    try testing.expectEqualStrings("#222222", sheet.lookup("brand").?);
    try testing.expect(sheet.lookup("nope") == null);
}

test "fromSource collects directives and skips everything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const sheet = try fromSource(arena_state.allocator(),
        \\just a stray line
        \\:color brand #7c3aed
        \\:unknown directive here
        \\
        \\  :color soft #9aa4b2
    );
    try testing.expectEqual(@as(usize, 2), sheet.colors.len);
    try testing.expectEqualStrings("#7c3aed", sheet.lookup("brand").?);
    try testing.expectEqualStrings("#9aa4b2", sheet.lookup("soft").?);
}

test "concat layers the second sheet over the first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const site: Sheet = .{ .colors = &.{.{ .name = "brand", .value = "#111111" }} };
    const proj: Sheet = .{ .colors = &.{.{ .name = "brand", .value = "#222222" }} };
    const merged = try concat(arena_state.allocator(), site, proj);
    try testing.expectEqualStrings("#222222", merged.lookup("brand").?);
    // degenerate cases pass through without allocating
    try testing.expectEqualStrings("#111111", (try concat(arena_state.allocator(), site, .empty)).lookup("brand").?);
}

test "load reads a .sxh from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theme.sxh", .data = ":color brand #7c3aed\n" });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const sheet = try load(testing.io, arena_state.allocator(), tmp.dir, "theme.sxh");
    try testing.expectEqualStrings("#7c3aed", sheet.lookup("brand").?);
}
