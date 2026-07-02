//! HTML text/attribute escaping — the one leaf every HTML-emitting file needs.

const std = @import("std");
const Writer = std.Io.Writer;

pub fn escapeChar(w: *Writer, c: u8) Writer.Error!void {
    switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    }
}

pub fn escapeInto(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| try escapeChar(w, c);
}

pub fn escapeAttrInto(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

// ---- tests ------------------------------------------------------------------

test "escapeInto escapes & < >" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try escapeInto(&w, "a & b <tag>");
    try std.testing.expectEqualStrings("a &amp; b &lt;tag&gt;", w.buffered());
}

test "escapeAttrInto also escapes double quotes" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try escapeAttrInto(&w, "say \"hi\" <b>");
    try std.testing.expectEqualStrings("say &quot;hi&quot; &lt;b&gt;", w.buffered());
}
