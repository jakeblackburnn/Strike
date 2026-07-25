//! Typography sheets: the reserved `:` directive namespace and the `Sheet`
//! scaffolding that will carry it.
//!
//! A *typography directive* is a block-position line starting with `:`. The
//! namespace is currently **reserved** — no directives are recognized, so
//! every `:` line is ordinary prose in a document and skipped in a `.sxh`
//! header file. (The original `:color` directive and its `(name)` block
//! prefix were removed pending a design that fits the strikedown = content /
//! strike = rendering-style split; see git history at 0.0.2.)
//!
//! The plumbing stays wired so the namespace can return as data, not
//! plumbing work: `strike.yaml`'s `header:` still loads `.sxh` files
//! (project layered over site, see `project.zig`) and seeds every document's
//! working sheet. The intended direction is **command aliases**
//! (`:thin-grid grid(2) skinny(80%)` defines `thin-grid`; `// thin-grid`
//! uses it): a `Sheet` maps alias names to raw command tokens, and
//! strikedown expands a reference by feeding those tokens through the
//! existing `parseCommand`/`applyCommand` → `Attrs` path — aliases resolve
//! to commands and ride the command → attribute → emitter pipeline, adding
//! zero new attribute plumbing and never an emitter special case keyed on
//! content.
//!
//! Fail-soft, like `yaml.zig`: a line that doesn't parse as a known directive
//! is simply not a directive (in a document it stays prose; in a `.sxh` it is
//! skipped), and a missing/unreadable header file is the caller's problem to
//! degrade gracefully.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An immutable bundle of typography settings. Currently empty — the reserved
/// slot future directives fill. Sheets layer by concatenation (site header,
/// then project header, then in-document directives); later entries win.
pub const Sheet = struct {
    pub const empty: Sheet = .{};
};

/// One recognized directive. Empty while the namespace is reserved: no value
/// of this type can exist, so `parseLine` can only return null.
pub const Directive = enum {};

/// Parse one (left-trimmed) line as a directive, or null if it isn't one.
/// Nothing is recognized today — the `:` gate is kept so every caller (the
/// document parser, the `.sxh` loader, `isBlockStart`) stays wired for the
/// first real directive. Unknown keywords and malformed lines return null
/// (fail-soft: prose, not an error).
pub fn parseLine(line: []const u8) ?Directive {
    if (line.len < 2 or line[0] != ':') return null;
    return null;
}

/// Names usable where strikedown wants a bare identifier (group names today,
/// directive-defined aliases eventually): `[A-Za-z0-9_-]+`.
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
    _ = arena;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        _ = parseLine(line);
    }
    return .empty;
}

/// Layer `over` on top of `base` into one sheet (later entries win). Used to
/// stack the project header over the site header.
pub fn concat(arena: Allocator, base: Sheet, over: Sheet) Allocator.Error!Sheet {
    _ = arena;
    _ = base;
    return over;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "parseLine: the `:` namespace is reserved, nothing is recognized" {
    try testing.expect(parseLine(":color brand #7c3aed") == null);
    try testing.expect(parseLine(":margin 2rem") == null);
    try testing.expect(parseLine("plain prose") == null);
    try testing.expect(parseLine(":") == null);
}

test "isAliasName accepts [A-Za-z0-9_-]+ and nothing else" {
    try testing.expect(isAliasName("two_lists"));
    try testing.expect(isAliasName("Box-2"));
    try testing.expect(!isAliasName(""));
    try testing.expect(!isAliasName("b@d"));
    try testing.expect(!isAliasName("has space"));
}

test "fromSource yields an empty sheet without erroring" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try fromSource(arena_state.allocator(),
        \\just a stray line
        \\:color brand #7c3aed
        \\:unknown directive here
    );
}

test "load reads a .sxh from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theme.sxh", .data = ":color brand #7c3aed\n" });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try load(testing.io, arena_state.allocator(), tmp.dir, "theme.sxh");
}
