//! Typography sheets carry page typography and the `:` directive namespace's
//! **command aliases** (`docs/reference/design/010-aliases.md`, candidate B, decided
//! 2026-09-01): `:thin-grid grid(2) skinny(80%)` defines `thin-grid`;
//! `// figs thin-grid()` or `/thin-grid()` uses it, entering through the
//! same `word(args)`-shaped lookup as a real command (`Parser.resolveCommandToken`
//! in `strikedown.zig`) — a name-vs-command collision is impossible since
//! parens already separate the vocabularies, and a real command word can
//! never be aliased (`command.isCommandWord`).
//!
//! A definition resolves to `Attrs` right here, at parse time: each token
//! after the name runs through `command.parseCommand`/`applyCommand`, and a
//! bad token fails the whole `:` line (fail-soft — it stays ordinary prose,
//! same as any other unrecognized directive). A *use* just merges that
//! precomputed `Attrs` (`command.mergeAttrs`) — aliases add vocabulary, never
//! a second attribute pipeline.
//!
//! `strike.yaml`'s `header:` loads `.sxh` files (project layered over site,
//! see `project.zig`) and seeds every document's base sheet; the header's
//! validated font, measure, size, and leading values also reach page emitters.
//! In-document
//! `:` lines add to it as parsing proceeds (`Parser.doc_aliases`). Later
//! definitions win (`concat`, and `Parser.lookupAlias`'s most-recent-first
//! scan) — a document can locally override a project-level alias.
//!
//! Fail-soft, like `yaml.zig`: a line that doesn't parse as a clean
//! definition is simply not a directive (in a document it stays prose; in a
//! `.sxh` it is skipped), and a missing/unreadable header file is the
//! caller's problem to degrade gracefully.

const std = @import("std");
const model = @import("strikedown/model.zig");
const command = @import("strikedown/command.zig");
const Allocator = std.mem.Allocator;

/// One alias definition: `name` (validated `isAliasName`) bound to the
/// `Attrs` its command list resolved to.
pub const NamedAlias = struct {
    name: []const u8,
    attrs: model.Attrs,
};

/// Page typography carried by a header. Values are validated CSS tokens so
/// emitters can use them without accepting arbitrary CSS from a document.
pub const TypeStyle = struct {
    font: ?Font = null,
    measure: ?[]const u8 = null,
    size: ?[]const u8 = null,
    leading: ?[]const u8 = null,

    pub const Font = enum { serif, sans, mono };

    pub fn layer(base: TypeStyle, over: TypeStyle) TypeStyle {
        return .{
            .font = over.font orelse base.font,
            .measure = over.measure orelse base.measure,
            .size = over.size orelse base.size,
            .leading = over.leading orelse base.leading,
        };
    }
};

/// An immutable, ordered bundle of alias definitions. Sheets layer by
/// concatenation (site header, then project header, then in-document
/// directives); `get` and `Parser.lookupAlias` both search most-recent-first,
/// so later entries win without needing a hash map or dedup pass.
pub const Sheet = struct {
    aliases: []const NamedAlias = &.{},
    typography: TypeStyle = .{},

    pub const empty: Sheet = .{};

    /// The most recently defined alias named `name`, if any.
    pub fn get(s: Sheet, name: []const u8) ?model.Attrs {
        var i = s.aliases.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, s.aliases[i].name, name)) return s.aliases[i].attrs;
        }
        return null;
    }
};

/// One recognized directive: today, only an alias definition.
pub const Directive = union(enum) {
    alias: NamedAlias,
};

/// Parse one (left-trimmed) line as a directive, or null if it isn't one.
/// A clean `:name command()+` line — name is `isAliasName` and not a
/// reserved command word, every following token parses as a real command —
/// is a definition; anything else (`:only-a-name`, `:x grid(0)`, a leading
/// space before the name) is not a directive at all and stays prose
/// (fail-soft: unknown keywords and malformed lines return null, never an
/// error).
pub fn parseLine(line: []const u8) ?Directive {
    if (line.len < 2 or line[0] != ':') return null;
    var it: command.CommandTokenizer = .{ .rest = line[1..] };
    const name = it.next() orelse return null;
    if (!isAliasName(name) or command.isCommandWord(name)) return null;
    var attrs: model.Attrs = .{};
    var any = false;
    while (it.next()) |tok| {
        const cmd = command.parseCommand(tok) orelse return null;
        command.applyCommand(&attrs, cmd);
        any = true;
    }
    if (!any) return null; // a bare `:name` with no commands defines nothing
    return .{ .alias = .{ .name = name, .attrs = attrs } };
}

/// Names usable where strikedown wants a bare identifier (group names,
/// directive-defined aliases): `[A-Za-z0-9_-]+`.
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
    const src = try dir.readFileAlloc(io, path, arena, .limited(max_header_bytes));
    return fromSource(arena, src);
}

const max_header_bytes = 1 << 20;

/// Collect a sheet from directive source text (the pure core of `load`).
pub fn fromSource(arena: Allocator, src: []const u8) Allocator.Error!Sheet {
    var aliases: std.ArrayList(NamedAlias) = .empty;
    var typography: TypeStyle = .{};
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (parseTypography(line)) |entry| {
            switch (entry) {
                .font => |v| typography.font = v,
                .measure => |v| typography.measure = v,
                .size => |v| typography.size = v,
                .leading => |v| typography.leading = v,
            }
            continue;
        }
        if (parseLine(line)) |d| switch (d) {
            .alias => |a| try aliases.append(arena, a),
        };
    }
    return .{ .aliases = try aliases.toOwnedSlice(arena), .typography = typography };
}

const TypographyEntry = union(enum) {
    font: TypeStyle.Font,
    measure: []const u8,
    size: []const u8,
    leading: []const u8,
};

fn parseTypography(line: []const u8) ?TypographyEntry {
    if (line.len == 0 or line[0] == '#') return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (std.mem.eql(u8, key, "font")) {
        const font = std.meta.stringToEnum(TypeStyle.Font, value) orelse return null;
        return .{ .font = font };
    }
    if (std.mem.eql(u8, key, "measure") or std.mem.eql(u8, key, "size")) {
        if (!std.mem.endsWith(u8, value, "rem")) return null;
        const number = value[0 .. value.len - 3];
        const n = parseDecimal(number) orelse return null;
        const max: f64 = if (std.mem.eql(u8, key, "measure")) 120 else 5;
        if (n < 0.5 or n > max) return null;
        return if (std.mem.eql(u8, key, "measure")) .{ .measure = value } else .{ .size = value };
    }
    if (std.mem.eql(u8, key, "leading")) {
        const n = parseDecimal(value) orelse return null;
        if (n < 1 or n > 3) return null;
        return .{ .leading = value };
    }
    return null;
}

fn parseDecimal(value: []const u8) ?f64 {
    if (value.len == 0 or value.len > 12) return null;
    var dots: usize = 0;
    for (value) |c| {
        if (c == '.') {
            dots += 1;
            if (dots > 1) return null;
        } else if (!std.ascii.isDigit(c)) return null;
    }
    if (value[0] == '.' or value[value.len - 1] == '.') return null;
    return std.fmt.parseFloat(f64, value) catch null;
}

/// Layer `over` on top of `base` into one sheet (later entries win). Used to
/// stack the project header over the site header.
pub fn concat(arena: Allocator, base: Sheet, over: Sheet) Allocator.Error!Sheet {
    if (base.aliases.len == 0) return .{ .aliases = over.aliases, .typography = TypeStyle.layer(base.typography, over.typography) };
    if (over.aliases.len == 0) return .{ .aliases = base.aliases, .typography = TypeStyle.layer(base.typography, over.typography) };
    const combined = try arena.alloc(NamedAlias, base.aliases.len + over.aliases.len);
    @memcpy(combined[0..base.aliases.len], base.aliases);
    @memcpy(combined[base.aliases.len..], over.aliases);
    return .{ .aliases = combined, .typography = TypeStyle.layer(base.typography, over.typography) };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "parseLine: a clean `:name command()+` line defines an alias" {
    const d = parseLine(":thin-grid grid(2) skinny(80%)").?;
    try testing.expectEqualStrings("thin-grid", d.alias.name);
    try testing.expectEqual(@as(usize, 2), d.alias.attrs.columns.?);
    try testing.expectEqual(@as(usize, 80), d.alias.attrs.width_pct.?);
}

test "parseLine: malformed or empty definitions stay prose" {
    try testing.expect(parseLine("plain prose") == null);
    try testing.expect(parseLine(":") == null);
    try testing.expect(parseLine(":only-a-name") == null); // no commands
    try testing.expect(parseLine(":x grid(0)") == null); // bad command args
    try testing.expect(parseLine(":grid grid(2)") == null); // command word reserved
    try testing.expect(parseLine(":b@d grid(2)") == null); // invalid name
}

test "isAliasName accepts [A-Za-z0-9_-]+ and nothing else" {
    try testing.expect(isAliasName("two_lists"));
    try testing.expect(isAliasName("Box-2"));
    try testing.expect(!isAliasName(""));
    try testing.expect(!isAliasName("b@d"));
    try testing.expect(!isAliasName("has space"));
}

test "fromSource collects definitions and skips prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try fromSource(arena_state.allocator(),
        \\just a stray line
        \\:thin-grid grid(2) skinny(80%)
        \\:unknown directive here
        \\:muted-box color(muted) collapse()
    );
    try testing.expectEqual(@as(usize, 2), s.aliases.len);
    try testing.expectEqual(@as(usize, 2), s.get("thin-grid").?.columns.?);
    try testing.expect(s.get("muted-box").?.collapse != null);
    try testing.expect(s.get("nope") == null);
}

test "concat layers base under over; a later same-name definition wins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try fromSource(arena, ":thin-grid grid(2) skinny(80%)\n:box color(muted)");
    const over = try fromSource(arena, ":thin-grid grid(3)");
    const s = try concat(arena, base, over);
    try testing.expectEqual(@as(usize, 3), s.get("thin-grid").?.columns.?);
    try testing.expect(s.get("thin-grid").?.width_pct == null); // over's definition replaces, not merges
    try testing.expect(s.get("box").?.text_color != null); // base-only entry survives
}

test "load reads a .sxh from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theme.sxh", .data = ":thin-grid grid(2) skinny(80%)\n" });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try load(testing.io, arena_state.allocator(), tmp.dir, "theme.sxh");
    try testing.expectEqual(@as(usize, 2), s.get("thin-grid").?.columns.?);
}

test "typography parses safely and layers by field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try fromSource(arena,
        \\font: serif
        \\measure: 34rem
        \\size: 1.05rem
        \\leading: 1.7
        \\:fig caption(bottom)
    );
    const over = try fromSource(arena,
        \\font: mono
        \\size: 99rem
        \\leading: 1.5; color:red
    );
    const layered = try concat(arena, base, over);
    try testing.expectEqual(TypeStyle.Font.mono, layered.typography.font.?);
    try testing.expectEqualStrings("34rem", layered.typography.measure.?);
    try testing.expectEqualStrings("1.05rem", layered.typography.size.?);
    try testing.expectEqualStrings("1.7", layered.typography.leading.?);
    try testing.expect(layered.get("fig") != null);
}
