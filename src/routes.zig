//! Route shape — the one place the mapping from document *paths* to site
//! *routes* is defined. `project.zig` builds the route table with these rules
//! at scan time; `render_html.zig` re-applies them at emit time to resolve
//! doc-relative link targets. They used to hand-mirror each other; now both
//! import this leaf (std only — safe from any context, no I/O).

const std = @import("std");

/// Strip a trailing `.sx` and/or `.md` (handles the `.sx.md` double extension).
pub fn stripExtension(name: []const u8) []const u8 {
    var s = name;
    if (std.mem.endsWith(u8, s, ".md")) s = s[0 .. s.len - ".md".len];
    if (std.mem.endsWith(u8, s, ".sx")) s = s[0 .. s.len - ".sx".len];
    return s;
}

/// Collapse a `main` stem to its containing folder's route: main.* docs are
/// served *at* their directory ("main" -> "", "a/main" -> "a"; anything else
/// passes through).
pub fn collapseMain(stem: []const u8) []const u8 {
    if (std.mem.eql(u8, stem, "main")) return "";
    if (std.mem.endsWith(u8, stem, "/main")) return stem[0 .. stem.len - "/main".len];
    return stem;
}

/// A resolved doc-relative link target: the (possibly popped) base route the
/// link lands under, and the extensionless, main-collapsed stem. Both are
/// slices into the inputs — no allocation.
pub const DocTarget = struct { base: []const u8, stem: []const u8 };

/// Resolve a doc-relative path against `base` (the linking document's
/// containing-directory route): leading `./`s drop, each leading `../` pops a
/// segment off `base` — never past `floor` (the site mount point; "" means
/// the site root) — then the extension drops and a trailing `main` segment
/// collapses to its folder's route.
pub fn resolveDocTarget(base: []const u8, path: []const u8, floor: []const u8) DocTarget {
    var b = base;
    var p = path;
    while (true) {
        if (std.mem.startsWith(u8, p, "./")) {
            p = p[2..];
        } else if (std.mem.startsWith(u8, p, "../")) {
            p = p[3..];
            if (b.len > floor.len) {
                b = if (std.mem.lastIndexOfScalar(u8, b, '/')) |i| b[0..i] else "";
                if (b.len < floor.len) b = floor;
            }
        } else break;
    }
    return .{ .base = b, .stem = collapseMain(stripExtension(p)) };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "stripExtension handles .md, .sx, and .sx.md" {
    try testing.expectEqualStrings("a", stripExtension("a.md"));
    try testing.expectEqualStrings("a", stripExtension("a.sx"));
    try testing.expectEqualStrings("a", stripExtension("a.sx.md"));
    try testing.expectEqualStrings("topo/algebra", stripExtension("topo/algebra.md"));
}

test "collapseMain maps main stems to folder routes" {
    try testing.expectEqualStrings("", collapseMain("main"));
    try testing.expectEqualStrings("a", collapseMain("a/main"));
    try testing.expectEqualStrings("a/b", collapseMain("a/b/main"));
    try testing.expectEqualStrings("remain", collapseMain("remain"));
    try testing.expectEqualStrings("a/domain", collapseMain("a/domain"));
}

test "resolveDocTarget drops ./, pops ../, strips and collapses" {
    const t1 = resolveDocTarget("/p/a", "./x.md", "");
    try testing.expectEqualStrings("/p/a", t1.base);
    try testing.expectEqualStrings("x", t1.stem);

    const t2 = resolveDocTarget("/p/a", "../y/main.sx", "");
    try testing.expectEqualStrings("/p", t2.base);
    try testing.expectEqualStrings("y", t2.stem);

    const t3 = resolveDocTarget("/p", "../../z.md", "");
    try testing.expectEqualStrings("", t3.base);
    try testing.expectEqualStrings("z", t3.stem);
}

test "resolveDocTarget clamps at the floor" {
    // No floor: pops clamp at the site root.
    const t1 = resolveDocTarget("/p", "../../../x.md", "");
    try testing.expectEqualStrings("", t1.base);
    // A mount floor: pops stop at the mount point, extra ../ are consumed.
    const t2 = resolveDocTarget("/mnt/docs/p/a", "../../../../x.md", "/mnt/docs");
    try testing.expectEqualStrings("/mnt/docs", t2.base);
    try testing.expectEqualStrings("x", t2.stem);
}
