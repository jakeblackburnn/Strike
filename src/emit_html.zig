//! `doc.Doc` → HTML. The emitter owns every output-format concern; nothing
//! in `doc.zig`/`parse.zig` is HTML-specific — a future PDF backend would be
//! a sibling file walking the same tree (see `dev/terms.md`, "two-stage
//! rendering").

const std = @import("std");
const doc = @import("doc.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const RenderOptions = struct {
    /// The page `<title>`, used only when `fragment` is false.
    title: []const u8 = "strike",
    /// true: just the body fragment. false: a standalone page.
    fragment: bool = false,
};

/// Parse + emit, the convenience every caller uses.
pub fn render(gpa: Allocator, src: []const u8, opts: RenderOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const d = try @import("parse.zig").parse(arena_state.allocator(), src);
    const fragment = try emit(gpa, d);
    defer gpa.free(fragment);
    if (opts.fragment) return gpa.dupe(u8, fragment);
    return page(gpa, opts.title, fragment);
}

/// Walks `doc.blocks` into an HTML fragment.
pub fn emit(gpa: Allocator, d: doc.Doc) ![]u8 {
    var w: Writer.Allocating = .init(gpa);
    defer w.deinit();
    for (d.blocks) |block| try emitBlock(&w.writer, block);
    return w.toOwnedSlice();
}

fn emitBlock(w: *Writer, block: doc.Block) !void {
    switch (block) {
        .heading => |h| {
            try w.print("<h{d}>", .{h.level});
            try emitInlines(w, h.inlines);
            try w.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |inlines| {
            try w.writeAll("<p>");
            try emitInlines(w, inlines);
            try w.writeAll("</p>\n");
        },
        .code => |c| {
            try w.writeAll("<pre><code");
            if (c.lang.len > 0) {
                try w.writeAll(" class=\"language-");
                try html.escapeAttrInto(w, c.lang);
                try w.writeAll("\"");
            }
            try w.writeAll(">");
            try html.escapeInto(w, c.text);
            try w.writeAll("</code></pre>\n");
        },
    }
}

fn emitInlines(w: *Writer, inlines: []const doc.Inline) Writer.Error!void {
    for (inlines) |in| try emitInline(w, in);
}

fn emitInline(w: *Writer, in: doc.Inline) Writer.Error!void {
    switch (in) {
        .text => |s| try html.escapeInto(w, s),
        .code => |s| {
            try w.writeAll("<code>");
            try html.escapeInto(w, s);
            try w.writeAll("</code>");
        },
        .strong => |children| {
            try w.writeAll("<strong>");
            try emitInlines(w, children);
            try w.writeAll("</strong>");
        },
        .em => |children| {
            try w.writeAll("<em>");
            try emitInlines(w, children);
            try w.writeAll("</em>");
        },
    }
}

/// Wraps a fragment in a standalone page: a readable column, system font,
/// nothing else. Provisional (`dev/terms.md`), not a design commitment.
pub fn page(gpa: Allocator, title: []const u8, fragment: []const u8) ![]u8 {
    var w: Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.writeAll("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">\n<title>");
    try html.escapeInto(&w.writer, title);
    try w.writer.writeAll(
        \\</title>
        \\<style>
        \\  body { max-width: 40rem; margin: 3rem auto; padding: 0 1rem;
        \\         font-family: system-ui, sans-serif; line-height: 1.5; }
        \\  pre { overflow-x: auto; padding: 0.75rem; background: #f4f4f4; }
        \\  code { font-family: ui-monospace, monospace; }
        \\</style>
        \\</head><body>
        \\
    );
    try w.writer.writeAll(fragment);
    try w.writer.writeAll("</body></html>\n");
    return w.toOwnedSlice();
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

fn expectRender(src: []const u8, expected: []const u8) !void {
    const got = try render(testing.allocator, src, .{ .fragment = true });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "heading" {
    try expectRender("# Title", "<h1>Title</h1>\n");
}

test "paragraph" {
    try expectRender("hello world", "<p>hello world</p>\n");
}

test "fenced code with a language, escaped" {
    try expectRender("```zig\nconst x = 1 < 2;\n```", "<pre><code class=\"language-zig\">const x = 1 &lt; 2;\n</code></pre>\n");
}

test "fenced code with no info string" {
    try expectRender("```\nplain\n```", "<pre><code>plain\n</code></pre>\n");
}

test "inline code, strong, em" {
    try expectRender("`x` **b** *i*", "<p><code>x</code> <strong>b</strong> <em>i</em></p>\n");
}

test "nested strong/em" {
    try expectRender("**bold *and* text**", "<p><strong>bold <em>and</em> text</strong></p>\n");
}

test "text is escaped" {
    try expectRender("a & b < c", "<p>a &amp; b &lt; c</p>\n");
}

test "page() wraps a fragment with a title" {
    const out = try render(testing.allocator, "# Hi", .{ .title = "My Doc" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<title>My Doc</title>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<h1>Hi</h1>") != null);
}
