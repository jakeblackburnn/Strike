//! The static-asset extension whitelist: which files outside the `.md`/`.sx`
//! document set are servable/exportable, and their MIME type. `server.zig`'s
//! dev-server asset fallback and `main.zig`'s static-export copy step both
//! need the exact same policy — this is the shared leaf they import so the
//! two can't drift, the same reason `routes.zig` exists.

const std = @import("std");

const mime_types = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".css", .mime = "text/css" },
    .{ .ext = ".js", .mime = "text/javascript" },
    .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
};

/// The MIME type for a known static-asset extension, or `null` if `path`'s
/// extension isn't on the whitelist (including `.md`/`.sx` documents, which
/// are never served as static assets).
pub fn mimeFor(path: []const u8) ?[]const u8 {
    for (mime_types) |m| {
        if (std.ascii.endsWithIgnoreCase(path, m.ext)) return m.mime;
    }
    return null;
}

const testing = std.testing;

test "mimeFor knows asset extensions and rejects others" {
    try testing.expectEqualStrings("image/png", mimeFor("/img/cat.PNG").?);
    try testing.expectEqualStrings("text/css", mimeFor("/style.css").?);
    try testing.expect(mimeFor("/doc.md") == null);
    try testing.expect(mimeFor("/no-extension") == null);
}
