//! A small native PDF backend. It walks the same parsed block tree as HTML,
//! lays out text in points, and writes PDF 1.4 objects directly. No browser or
//! external process is involved.

const std = @import("std");
const strikedown = @import("strikedown.zig");
const sheet = @import("sheet.zig");
const model = @import("strikedown/model.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    sheet: sheet.Sheet = .empty,
    page_size: PageSize = .letter,
    margin_pt: f64 = 54,
};

pub const PageSize = enum { letter, a4 };

pub fn render(arena: Allocator, src: []const u8, opts: Options) ![]u8 {
    const doc = try strikedown.parse(arena, src, opts.sheet);
    return emit(arena, doc, opts);
}

const Page = struct { stream: std.ArrayList(u8) = .empty };

const Layout = struct {
    a: Allocator,
    opts: Options,
    pages: std.ArrayList(Page) = .empty,
    page_w: f64,
    page_h: f64,
    x: f64 = 0,
    y: f64 = 0,
    start_y: f64 = 0,
    cols: usize = 1,
    col: usize = 0,
    font_size: f64 = 10.5,
    leading: f64 = 1.45,
    font: []const u8 = "F1",
    measure_pt: ?f64 = null,

    fn init(a: Allocator, opts: Options) !Layout {
        const dims: [2]f64 = switch (opts.page_size) {
            .letter => .{ 612, 792 },
            .a4 => .{ 595.28, 841.89 },
        };
        if (opts.margin_pt < 18 or opts.margin_pt > dims[0] / 3) return error.InvalidMargin;
        var self: Layout = .{ .a = a, .opts = opts, .page_w = dims[0], .page_h = dims[1] };
        const style = opts.sheet.typography;
        if (style.font) |f| self.font = switch (f) {
            .serif => "F1",
            .sans => "F2",
            .mono => "F3",
        };
        if (style.size) |v| self.font_size = (std.fmt.parseFloat(f64, v[0 .. v.len - 3]) catch 1) * 12;
        if (style.measure) |v| self.measure_pt = (std.fmt.parseFloat(f64, v[0 .. v.len - 3]) catch 34) * 12;
        if (style.leading) |v| self.leading = std.fmt.parseFloat(f64, v) catch 1.45;
        try self.newPage();
        return self;
    }

    fn newPage(self: *Layout) !void {
        try self.pages.append(self.a, .{});
        self.col = 0;
        self.start_y = self.page_h - self.opts.margin_pt;
        self.y = self.start_y;
        self.x = if (self.cols == 1) (self.page_w - self.colWidth()) / 2 else self.opts.margin_pt;
    }

    fn colWidth(self: *const Layout) f64 {
        const usable = self.page_w - 2 * self.opts.margin_pt;
        if (self.cols == 1) return if (self.measure_pt) |m| @min(usable, m) else usable;
        return (usable - @as(f64, @floatFromInt(self.cols - 1)) * 18) / @as(f64, @floatFromInt(self.cols));
    }

    fn advance(self: *Layout, height: f64) !void {
        if (self.y - height >= self.opts.margin_pt) return;
        if (self.col + 1 < self.cols) {
            self.col += 1;
            self.x = self.opts.margin_pt + @as(f64, @floatFromInt(self.col)) * (self.colWidth() + 18);
            self.y = self.start_y;
        } else try self.newPage();
    }

    fn line(self: *Layout, raw: []const u8, size: f64, bold: bool) !void {
        const height = size * self.leading;
        try self.advance(height);
        const escaped = try pdfEscape(self.a, raw);
        const font = if (bold) "F4" else self.font;
        const cmd = try std.fmt.allocPrint(self.a, "BT /{s} {d:.2} Tf {d:.2} {d:.2} Td ({s}) Tj ET\n", .{ font, size, self.x, self.y, escaped });
        try self.pages.items[self.pages.items.len - 1].stream.appendSlice(self.a, cmd);
        self.y -= height;
    }

    fn paragraph(self: *Layout, raw: []const u8, size: f64, bold: bool) !void {
        const width = self.colWidth();
        // Base-14 font metrics vary by glyph; 0.52em is conservative for
        // readable wrapping and keeps long lines inside their columns.
        const max_chars: usize = @max(12, @as(usize, @intFromFloat(width / (size * 0.52))));
        var words = std.mem.tokenizeAny(u8, raw, " \t\r\n");
        var buf: std.ArrayList(u8) = .empty;
        while (words.next()) |word| {
            if (buf.items.len > 0 and buf.items.len + word.len + 1 > max_chars) {
                try self.line(buf.items, size, bold);
                buf.clearRetainingCapacity();
            }
            if (buf.items.len > 0) try buf.append(self.a, ' ');
            try buf.appendSlice(self.a, word);
        }
        if (buf.items.len > 0) try self.line(buf.items, size, bold);
        self.y -= size * 0.55;
    }

    fn blocks(self: *Layout, items: []const model.Block) anyerror!void {
        for (items) |block| switch (block.kind) {
            .heading => |h| {
                const raw = try inlineText(self.a, h.inlines);
                const size: f64 = switch (h.level) {
                    1 => 20,
                    2 => 15,
                    else => 12,
                };
                try self.advance(size * self.leading * 2);
                self.y -= size * 0.45;
                try self.paragraph(raw, size, true);
            },
            .paragraph => |p| try self.paragraph(try inlineText(self.a, p), self.font_size, false),
            .code => |c| {
                var lines = std.mem.splitScalar(u8, c.text, '\n');
                while (lines.next()) |line_text| if (line_text.len > 0) {
                    try self.line(line_text, self.font_size * 0.85, false);
                };
                self.y -= self.font_size * 0.7;
            },
            .quote => |q| for (q.paras) |p| try self.paragraph(try inlineText(self.a, p), self.font_size, false),
            .list => |l| {
                for (l.items, 0..) |item, i| {
                    const body = try inlineText(self.a, item.text);
                    const marker = if (l.plain) "" else if (l.ordered)
                        try std.fmt.allocPrint(self.a, "{d}. ", .{l.start + i})
                    else
                        "- ";
                    try self.paragraph(try std.fmt.allocPrint(self.a, "{s}{s}", .{ marker, body }), self.font_size, false);
                    for (item.tail) |tail| switch (tail) {
                        .line => |t| try self.paragraph(try inlineText(self.a, t), self.font_size, false),
                        .list => |nested| try self.blocks(&.{.{ .kind = .{ .list = nested } }}),
                    };
                }
            },
            .table => |t| {
                for (t.header) |cell| try self.paragraph(try inlineText(self.a, cell), self.font_size, true);
                for (t.rows) |row| for (row) |cell| try self.paragraph(try inlineText(self.a, cell), self.font_size, false);
            },
            .math => |m| try self.paragraph(m, self.font_size, false),
            .rule => {
                try self.advance(12);
                const cmd = try std.fmt.allocPrint(self.a, "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ self.x, self.y, self.x + self.colWidth(), self.y });
                try self.pages.items[self.pages.items.len - 1].stream.appendSlice(self.a, cmd);
                self.y -= 12;
            },
            .spacer => self.y -= 24,
            .group => |g| {
                if (block.attrs.flow_columns) |n| {
                    self.cols = n;
                    self.col = 0;
                    self.x = self.opts.margin_pt;
                    self.start_y = self.y;
                    for (g.sections) |section| try self.blocks(section);
                    self.cols = 1;
                    self.col = 0;
                    // The next full-width block starts on a new page.
                    try self.newPage();
                } else for (g.sections) |section| try self.blocks(section);
            },
        };
    }
};

fn inlineText(a: Allocator, inlines: []const model.Inline) anyerror![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (inlines) |item| switch (item) {
        .text, .code, .math, .autolink => |s| try out.appendSlice(a, s),
        .image => |im| try out.appendSlice(a, im.alt),
        .link => |l| try out.appendSlice(a, try inlineText(a, l.children)),
        .strong, .em, .strong_em, .strike => |s| try out.appendSlice(a, try inlineText(a, s)),
        .color_span => |s| try out.appendSlice(a, try inlineText(a, s.children)),
        .cite_span => try out.appendSlice(a, "[citation]"),
    };
    return try out.toOwnedSlice(a);
}

fn pdfEscape(a: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        if (c == '(' or c == ')' or c == '\\') try out.append(a, '\\');
        try out.append(a, if (c >= 32 and c < 127) c else '?');
    }
    return out.items;
}

pub fn emit(a: Allocator, doc: model.Doc, opts: Options) ![]u8 {
    var layout = try Layout.init(a, opts);
    try layout.blocks(doc.blocks);
    if (layout.pages.items.len > 1 and layout.pages.items[layout.pages.items.len - 1].stream.items.len == 0)
        layout.pages.items.len -= 1;

    var out: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    try out.appendSlice(a, "%PDF-1.4\n");
    const count = layout.pages.items.len;
    const font_obj = 3 + 2 * count;
    try obj(a, &out, &offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>");
    var kids: std.ArrayList(u8) = .empty;
    for (0..count) |i| try kids.appendSlice(a, try std.fmt.allocPrint(a, "{d} 0 R ", .{3 + 2 * i}));
    try obj(a, &out, &offsets, 2, try std.fmt.allocPrint(a, "<< /Type /Pages /Count {d} /Kids [{s}] >>", .{ count, kids.items }));
    for (layout.pages.items, 0..) |page, i| {
        const page_id = 3 + 2 * i;
        const content_id = page_id + 1;
        try obj(a, &out, &offsets, page_id, try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.2} {d:.2}] /Resources << /Font << /F1 {d} 0 R /F2 {d} 0 R /F3 {d} 0 R /F4 {d} 0 R >> >> /Contents {d} 0 R >>", .{ layout.page_w, layout.page_h, font_obj, font_obj + 1, font_obj + 2, font_obj + 3, content_id }));
        try obj(a, &out, &offsets, content_id, try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}endstream", .{ page.stream.items.len, page.stream.items }));
    }
    for ([_][]const u8{ "Times-Roman", "Helvetica", "Courier", "Times-Bold" }, 0..) |name, i| {
        try obj(a, &out, &offsets, font_obj + i, try std.fmt.allocPrint(a, "<< /Type /Font /Subtype /Type1 /BaseFont /{s} >>", .{name}));
    }
    const xref = out.items.len;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "xref\n0 {d}\n0000000000 65535 f \n", .{offsets.items.len + 1}));
    for (offsets.items) |offset| try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>10} 00000 n \n", .{offset}));
    try out.appendSlice(a, try std.fmt.allocPrint(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ offsets.items.len + 1, xref }));
    return try out.toOwnedSlice(a);
}

fn obj(a: Allocator, out: *std.ArrayList(u8), offsets: *std.ArrayList(usize), id: usize, body: []const u8) !void {
    std.debug.assert(offsets.items.len + 1 == id);
    try offsets.append(a, out.items.len);
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d} 0 obj\n{s}\nendobj\n", .{ id, body }));
}

test "native PDF contains a page and a source-ordered flow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pdf = try render(a, "# Report\n\n// body flow(2)\n\nFirst.\n\nSecond.\n\n// end body", .{});
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(First.)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Second.)") != null);
}

test "flow continues across physical pages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "// body flow(2)\n\n");
    for (0..120) |_| try source.appendSlice(a, "A paragraph with several words that fills some space.\n\n");
    try source.appendSlice(a, "Final marker.\n\n// end body\n");
    const pdf = try render(a, source.items, .{});
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 1 ") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Final marker.)") != null);
}

test "page_size selects the matching MediaBox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const letter = try render(a, "Hello.", .{ .page_size = .letter });
    try std.testing.expect(std.mem.indexOf(u8, letter, "/MediaBox [0 0 612.00 792.00]") != null);
    const a4 = try render(a, "Hello.", .{ .page_size = .a4 });
    try std.testing.expect(std.mem.indexOf(u8, a4, "/MediaBox [0 0 595.28 841.89]") != null);
}

test "margin outside the guard range is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidMargin, render(a, "Hello.", .{ .margin_pt = 10 }));
    try std.testing.expectError(error.InvalidMargin, render(a, "Hello.", .{ .margin_pt = 300 }));
    _ = try render(a, "Hello.", .{ .margin_pt = 18 }); // the boundary itself is accepted
}

test "Layout.init reads typography: font, scaled size, leading" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const opts: Options = .{ .sheet = .{ .typography = .{ .font = .mono, .size = "1.2rem", .leading = "1.6" } } };
    const layout = try Layout.init(a, opts);
    try std.testing.expectEqualStrings("F3", layout.font);
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), layout.font_size, 0.001); // 1.2rem * 12pt/rem
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), layout.leading, 0.001);
}
