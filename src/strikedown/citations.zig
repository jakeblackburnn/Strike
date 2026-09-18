//! The parse-end citations pass (`docs/reference/design/016-citations.md`):
//! adopts the document's `citations()` group, resolves every
//! `[text].cite(refs)` mark against its entry list, and writes backlinks and
//! previews as data on the tree. Runs once, after the block loop, inside
//! `parse` — every backend then walks an already-resolved `Doc`. Split out
//! of `strikedown.zig`.

const std = @import("std");
const model = @import("model.zig");
const command = @import("command.zig");
const inlines = @import("inline.zig");
const Allocator = std.mem.Allocator;

const Block = model.Block;
const Item = model.Item;
const List = model.List;
const Inline = model.Inline;
const CiteSpan = model.CiteSpan;

// ---- citations resolution ----------------------------------------------------

/// The parse-end citations pass (`docs/reference/design/016-citations.md`): adopt the
/// document's one citations() group (later ones degrade to plain groups with
/// a warning — the layout-level rule covers nesting, this covers siblings),
/// find its entry list (the first top-level numbered list in the group), lift
/// `[key]` entry prefixes, then resolve every citation mark's refs to entry
/// positions — writing mark sites, entry numbers, and backlinks as data on
/// the tree. Runs inside `parse` (pure, arena-owned), so every backend walks
/// the same resolved tree.
pub fn resolveCitations(arena: Allocator, warnings: *std.ArrayList([]const u8), blocks: []Block) Allocator.Error!void {
    var r: CiteResolver = .{ .arena = arena, .warnings = warnings };
    try r.scanGroups(blocks);
    try r.scanBlocks(blocks);
    try r.finish();
}

const CiteResolver = struct {
    arena: Allocator,
    warnings: *std.ArrayList([]const u8),
    /// The adopted group's entry items (the numbered list), or empty.
    entries: []Item = &.{},
    /// The first entry's number — the entry list's `start`, so marks,
    /// anchors, and previews all agree with the numbers the reader sees.
    first: u32 = 1,
    have_group: bool = false,
    /// Keys lifted from entries, in entry order (linear scan — entry lists
    /// are small).
    keys: std.ArrayList(struct { key: []const u8, num: u32 }) = .empty,
    /// Per-entry backlink site lists (index = entry number - 1).
    back: []std.ArrayList(u32) = &.{},
    site_count: u32 = 0,
    /// Marks seen with no citations group anywhere — warned once at the end.
    orphan_marks: usize = 0,

    fn scanGroups(r: *CiteResolver, blocks: []Block) Allocator.Error!void {
        for (blocks) |*b| {
            if (b.kind != .group) continue;
            if (b.attrs.citations) {
                if (r.have_group) {
                    command.clearCommand(&b.attrs, .citations);
                    try r.warnings.append(r.arena, try std.fmt.allocPrint(
                        r.arena,
                        "group '{s}': citations ignored (the document already has a citations group)",
                        .{command.groupLabel(b.kind.group.name)},
                    ));
                } else {
                    try r.adoptGroup(b);
                }
            }
            for (b.kind.group.sections) |section| try r.scanGroups(section);
        }
    }

    /// Take `b` as the document's citations group: locate the entry list and
    /// register its entries. No numbered list means the command degrades (the
    /// group renders plain) with a warning.
    fn adoptGroup(r: *CiteResolver, b: *Block) Allocator.Error!void {
        const arena = r.arena;
        const g = b.kind.group;
        var list: ?List = null;
        outer: for (g.sections) |section| for (section) |inner| {
            if (inner.kind == .list and inner.kind.list.ordered) {
                list = inner.kind.list;
                break :outer;
            }
        };
        const l = list orelse {
            command.clearCommand(&b.attrs, .citations);
            try r.warnings.append(arena, try std.fmt.allocPrint(
                arena,
                "group '{s}': citations ignored (no numbered list in the group)",
                .{command.groupLabel(g.name)},
            ));
            return;
        };
        r.have_group = true;
        r.entries = l.items;
        r.first = @intCast(l.start);
        // `collapse()` on the same opener would swallow the bibliography the
        // marks link into — the citations element wins, the collapse drops.
        if (b.attrs.collapse != null) {
            command.clearCommand(&b.attrs, .collapse);
            try r.warnings.append(arena, try std.fmt.allocPrint(
                arena,
                "group '{s}': collapse ignored on the citations group",
                .{command.groupLabel(g.name)},
            ));
        }
        r.back = try arena.alloc(std.ArrayList(u32), l.items.len);
        for (r.back) |*sites| sites.* = .empty;
        for (l.items, 0..) |*item, i| {
            const num: u32 = @intCast(l.start + i);
            item.cite_entry = num;
            try r.liftKey(item, num);
        }
    }

    /// Lift a leading `[key] ` off an entry's text, registering key → entry
    /// number. Only a clean key shape followed by a space (or nothing) lifts
    /// — an all-digit or otherwise non-key bracket stays literal prose, and a
    /// leading link/task box already owns the `[` and never reaches here.
    fn liftKey(r: *CiteResolver, item: *Item, num: u32) Allocator.Error!void {
        if (item.text.len == 0 or item.text[0] != .text) return;
        const s = item.text[0].text;
        if (s.len < 2 or s[0] != '[') return;
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return;
        const ref = inlines.parseCiteRef(s[1..close]) orelse return;
        if (ref.num != 0) return; // all digits — not a key
        if (close + 1 < s.len and s[close + 1] != ' ') return;
        const rest = std.mem.trimStart(u8, s[close + 1 ..], " ");
        if (rest.len == 0) {
            // Nothing left of the node — drop it rather than keeping an
            // empty `.text` in the item.
            item.text = item.text[1..];
        } else {
            item.text[0] = .{ .text = rest };
        }
        for (r.keys.items) |k| {
            if (std.mem.eql(u8, k.key, ref.raw)) {
                try r.warnings.append(r.arena, try std.fmt.allocPrint(
                    r.arena,
                    "citations: duplicate key [{s}] (the first entry wins)",
                    .{ref.raw},
                ));
                return;
            }
        }
        try r.keys.append(r.arena, .{ .key = ref.raw, .num = num });
    }

    fn scanBlocks(r: *CiteResolver, blocks: []Block) Allocator.Error!void {
        for (blocks) |*b| switch (b.kind) {
            .heading => |h| try r.scanInlines(h.inlines),
            .paragraph => |inls| try r.scanInlines(inls),
            .quote => |q| for (q.paras) |inls| try r.scanInlines(inls),
            .list => |l| try r.scanList(l),
            .table => |t| {
                for (t.header) |cell| try r.scanInlines(cell);
                for (t.rows) |row| for (row) |cell| try r.scanInlines(cell);
            },
            .group => |g| for (g.sections) |section| try r.scanBlocks(section),
            .code, .math, .rule, .spacer => {},
        };
    }

    fn scanList(r: *CiteResolver, l: List) Allocator.Error!void {
        for (l.items) |item| {
            try r.scanInlines(item.text);
            for (item.tail) |tail| switch (tail) {
                .line => |inls| try r.scanInlines(inls),
                .list => |sub| try r.scanList(sub),
            };
        }
    }

    fn scanInlines(r: *CiteResolver, inls: []Inline) Allocator.Error!void {
        for (inls) |*inl| switch (inl.*) {
            .cite_span => |*span| {
                try r.resolveMark(span);
                try r.scanInlines(span.children);
            },
            .link => |l| try r.scanInlines(l.children),
            .color_span => |cs| try r.scanInlines(cs.children),
            .strong, .em, .strong_em, .strike => |c| try r.scanInlines(c),
            .text, .code, .math, .image, .autolink => {},
        };
    }

    /// Number the mark's site, resolve each ref to an entry, record
    /// backlinks, and build the plain-text preview. Failed refs zero out and
    /// warn — the mark still renders, its dead refs inert.
    fn resolveMark(r: *CiteResolver, span: *CiteSpan) Allocator.Error!void {
        const arena = r.arena;
        r.site_count += 1;
        span.site = r.site_count;
        if (!r.have_group) {
            for (span.refs) |*ref| ref.num = 0;
            r.orphan_marks += 1;
            return;
        }
        var preview: std.ArrayList(u8) = .empty;
        for (span.refs, 0..) |*ref, ri| {
            if (ref.num == 0) {
                // A key ref, or a number no u32 holds (`parseCiteRef` left
                // it unresolved) — both miss the same way.
                ref.num = r.lookupKey(ref.raw) orelse {
                    try r.warnNoEntry(ref.raw);
                    continue;
                };
            } else if (ref.num < r.first or ref.num - r.first >= r.entries.len) {
                try r.warnNoEntry(ref.raw);
                ref.num = 0;
                continue;
            }
            // A mark citing the same entry twice keeps one backlink and one
            // preview line; the sup still shows what the author wrote.
            const dup = for (span.refs[0..ri]) |prev| {
                if (prev.num == ref.num) break true;
            } else false;
            if (dup) continue;
            try r.back[ref.num - r.first].append(arena, span.site);
            if (preview.items.len > 0) try preview.append(arena, '\n');
            try preview.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}. ", .{ref.num}));
            try previewEntry(arena, &preview, r.entries[ref.num - r.first]);
        }
        span.preview = try preview.toOwnedSlice(arena);
    }

    /// The one degradation message for every unresolvable ref — unknown key,
    /// out-of-range number, overflowed number — so same-looking mistakes
    /// degrade the same way.
    fn warnNoEntry(r: *CiteResolver, raw: []const u8) Allocator.Error!void {
        try r.warnings.append(r.arena, try std.fmt.allocPrint(
            r.arena,
            "cite({s}): no matching entry",
            .{raw},
        ));
    }

    fn lookupKey(r: *CiteResolver, key: []const u8) ?u32 {
        for (r.keys.items) |k| {
            if (std.mem.eql(u8, k.key, key)) return k.num;
        }
        return null;
    }

    /// Hand each entry its backlink sites, and warn once about marks in a
    /// document with no citations group.
    fn finish(r: *CiteResolver) Allocator.Error!void {
        const arena = r.arena;
        for (r.entries, r.back) |*item, *sites| {
            item.cite_sites = try sites.toOwnedSlice(arena);
        }
        if (r.orphan_marks > 0) {
            try r.warnings.append(arena, try std.fmt.allocPrint(
                arena,
                "{d} citation mark(s) but no citations group",
                .{r.orphan_marks},
            ));
        }
    }
};

/// An entry's text as plain text (marker line plus soft-wrapped continuation
/// lines; nested lists skipped) — the mark's hover preview.
fn previewEntry(arena: Allocator, out: *std.ArrayList(u8), item: Item) Allocator.Error!void {
    try previewInlines(arena, out, item.text);
    for (item.tail) |tail| switch (tail) {
        .line => |inls| {
            try out.append(arena, ' ');
            try previewInlines(arena, out, inls);
        },
        .list => {},
    };
}

fn previewInlines(arena: Allocator, out: *std.ArrayList(u8), inls: []const Inline) Allocator.Error!void {
    for (inls) |inl| switch (inl) {
        .text, .code, .math, .autolink => |s| try out.appendSlice(arena, s),
        .image => |img| try out.appendSlice(arena, img.alt),
        .link => |l| try previewInlines(arena, out, l.children),
        .color_span => |cs| try previewInlines(arena, out, cs.children),
        .cite_span => |span| try previewInlines(arena, out, span.children),
        .strong, .em, .strong_em, .strike => |c| try previewInlines(arena, out, c),
    };
}

