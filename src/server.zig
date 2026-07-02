//! The `strike serve` HTTP server: a raw TCP listener speaking hand-written
//! HTTP/1.0 with `Connection: close` — deliberately the simplest thing that
//! works. Routes are pre-rendered at startup via `site.renderAll` and looked
//! up with a linear scan (tens of routes, not a hot path). On a route miss,
//! known static-asset extensions are read from the content directory per
//! request, so `![alt](img.png)` works while serving.
//!
//! This is the one file where socket I/O lives. It must never be imported by
//! `project.zig`/`site.zig`/`shell.zig` — `build.zig` `@import`s those at
//! configure time and has to stay `std.Build`-safe.

const std = @import("std");
const project = @import("project.zig");
const site = @import("site.zig");
const shell = @import("shell.zig");
const net = std.Io.net;
const Allocator = std.mem.Allocator;

/// What to serve: a content directory (a whole `Site`) or one .md/.sx file.
pub const Target = union(enum) { dir: []const u8, file: []const u8 };

pub const Options = struct {
    target: Target,
    host: []const u8,
    port: u16,
    /// Re-render on change and auto-reload the browser (see `Generation`).
    watch: bool = false,
};

/// Classify a serve target: an existing .md/.sx *file* serves standalone;
/// anything else is treated as a content directory.
pub fn classifyTarget(io: std.Io, path: []const u8) Target {
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".sx")) {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .dir = path };
        if (st.kind == .file) return .{ .file = path };
    }
    return .{ .dir = path };
}

/// Load the target, render every page into a cached route table, and serve
/// forever (Ctrl-C to stop).
///
/// `arena` is the process-lifetime allocator (never freed — today's contract
/// for everything the server keeps until exit). `gpa` backs `--watch`'s
/// per-generation arenas, which *are* freed on every swap.
pub fn run(arena: Allocator, gpa: Allocator, io: std.Io, opts: Options) !void {
    // Kept open for static-asset reads; for a single file, its parent dir (so
    // images next to the previewed file resolve too).
    const assets: ?std.Io.Dir = switch (opts.target) {
        .dir => |d| std.Io.Dir.cwd().openDir(io, d, .{ .iterate = true }) catch |err| return err,
        .file => |f| std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(f) orelse ".", .{}) catch null,
    };

    const not_found = try buildResponse(arena, "404 Not Found", "text/html; charset=utf-8", not_found_body);

    const address = try net.IpAddress.parse(opts.host, opts.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const shown = switch (opts.target) {
        .dir => |d| d,
        .file => |f| f,
    };
    std.debug.print("Serving {s} at http://{s}:{d}  (Ctrl-C to stop)\n", .{ shown, opts.host, opts.port });

    if (!opts.watch) {
        // Render-once (the default): everything lives on the caller's arena.
        const loaded = try loadTarget(io, arena, opts.target);
        var routes: std.ArrayList(Route) = .empty;
        try buildRoutes(arena, &routes, loaded, false);
        for (routes.items) |r| std.debug.print("  http://{s}:{d}{s}\n", .{ opts.host, opts.port, r.path });
        while (true) {
            const stream = server.accept(io) catch |err| {
                std.debug.print("accept error: {s}\n", .{@errorName(err)});
                continue;
            };
            serveConn(gpa, io, stream, routes.items, assets, loaded.base, not_found, null) catch |err| {
                std.debug.print("connection error: {s}\n", .{@errorName(err)});
            };
        }
    }

    // Watch mode: each accepted connection first checks the content
    // fingerprint and rebuilds the whole generation on change. The reload
    // script's ~400ms polling of /__strike/gen is what drives the checks, so
    // edits appear even when nobody manually refreshes.
    var gen = try buildGeneration(gpa, io, opts.target, 1);
    for (gen.routes) |r| std.debug.print("  http://{s}:{d}{s}\n", .{ opts.host, opts.port, r.path });
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        const fp = fingerprint(io, opts.target);
        if (fp != gen.fingerprint) {
            if (buildGeneration(gpa, io, opts.target, gen.id + 1)) |new_gen| {
                var old = gen;
                gen = new_gen;
                old.arena.deinit();
                std.debug.print("strike: content changed — reloaded (generation {d})\n", .{gen.id});
            } else |err| {
                // Keep serving the old generation; a later change (e.g. the
                // author fixing the problem) moves the fingerprint again.
                gen.fingerprint = fp;
                std.debug.print("strike: reload failed: {s} (still serving generation {d})\n", .{ @errorName(err), gen.id });
            }
        }
        serveConn(gpa, io, stream, gen.routes, assets, gen.base, not_found, gen.id) catch |err| {
            std.debug.print("connection error: {s}\n", .{@errorName(err)});
        };
    }
}

/// Load a serve target into a `Site` (a fresh directory handle per load, so
/// watch-mode rebuilds don't depend on a long-lived iterator).
fn loadTarget(io: std.Io, gpa: Allocator, target: Target) !project.Site {
    switch (target) {
        .dir => |d| {
            var content = try std.Io.Dir.cwd().openDir(io, d, .{ .iterate = true });
            defer content.close(io);
            return project.load(io, gpa, content);
        },
        .file => |f| return project.loadFile(io, gpa, std.Io.Dir.cwd(), f),
    }
}

// ---- watch ------------------------------------------------------------------

/// One complete built site: a route table plus the arena every byte of it
/// lives in, so a rebuild swaps atomically and frees the old generation in
/// one `deinit`. `id` is what `/__strike/gen` reports to the reload script.
const Generation = struct {
    arena: std.heap.ArenaAllocator,
    routes: []const Route,
    /// The site base path of this generation (a yaml edit can change it live).
    base: []const u8,
    id: u64,
    fingerprint: u64,
};

/// Build a full generation in its own arena: load → render → cached responses
/// with the reload script spliced in. On failure the arena is freed and the
/// caller keeps serving the previous generation.
fn buildGeneration(gpa: Allocator, io: std.Io, target: Target, id: u64) !Generation {
    // The fingerprint is taken *before* loading: if content changes mid-build
    // the stale hash won't match on the next request and we rebuild again.
    const fp = fingerprint(io, target);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const loaded = try loadTarget(io, a, target);
    var routes: std.ArrayList(Route) = .empty;
    try buildRoutes(a, &routes, loaded, true);
    return .{ .arena = arena, .routes = routes.items, .base = loaded.base, .id = id, .fingerprint = fp };
}

/// Hash the target's file metadata (name + size + mtime, recursive, dotfiles
/// skipped, every non-dot entry counted so yaml/asset edits register too):
/// cheap change detection for `--watch`. Errors hash a marker byte, so a
/// transiently missing file still moves the value.
fn fingerprint(io: std.Io, target: Target) u64 {
    var h = std.hash.Wyhash.init(0);
    switch (target) {
        .dir => |d| {
            var dir = std.Io.Dir.cwd().openDir(io, d, .{ .iterate = true }) catch return 0;
            defer dir.close(io);
            hashDir(io, &h, dir);
        },
        .file => |f| hashStat(io, &h, std.Io.Dir.cwd(), f),
    }
    return h.final();
}

fn hashDir(io: std.Io, h: *std.hash.Wyhash, dir: std.Io.Dir) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        h.update(entry.name);
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                    h.update("!");
                    continue;
                };
                defer sub.close(io);
                hashDir(io, h, sub);
            },
            else => hashStat(io, h, dir, entry.name),
        }
    }
}

fn hashStat(io: std.Io, h: *std.hash.Wyhash, dir: std.Io.Dir, name: []const u8) void {
    const st = dir.statFile(io, name, .{}) catch {
        h.update("?");
        return;
    };
    const mtime_ns: i128 = st.mtime.nanoseconds;
    h.update(std.mem.asBytes(&st.size));
    h.update(std.mem.asBytes(&mtime_ns));
}

/// Inject the live-reload client before the final `</body>` (appended when a
/// page somehow lacks one). Serve-only by construction: the splice happens
/// here, never in `shell.wrapPage`, so `strike build`/static export can't
/// ever emit the script.
fn spliceReload(gpa: Allocator, html: []const u8) ![]u8 {
    const at = std.mem.lastIndexOf(u8, html, "</body>") orelse html.len;
    return std.mem.concat(gpa, u8, &.{ html[0..at], shell.reload_script, html[at..] });
}

// ---- routes -------------------------------------------------------------

/// A request path mapped to its pre-built HTTP response.
const Route = struct { path: []const u8, response: []const u8 };

/// Build the route table from a loaded `Site` by rendering every page
/// (`site.renderAll`: the `/` picker or root home, each project home, each
/// document and folder page) and wrapping each into a cached HTTP response —
/// with the live-reload script spliced in when `watch` is set.
fn buildRoutes(gpa: Allocator, routes: *std.ArrayList(Route), loaded: project.Site, watch: bool) !void {
    const pages = try site.renderAll(gpa, loaded);
    for (pages) |p| {
        defer gpa.free(p.html);
        const html = if (watch) try spliceReload(gpa, p.html) else p.html;
        defer if (watch) gpa.free(html);
        try routes.append(gpa, .{
            .path = p.route,
            .response = try buildResponse(gpa, "200 OK", "text/html; charset=utf-8", html),
        });
    }
}

fn lookupRoute(routes: []const Route, path: []const u8) ?[]const u8 {
    // Linear scan: tens of routes, not a hot path.
    for (routes) |r| if (std.mem.eql(u8, r.path, path)) return r.response;
    return null;
}

const not_found_body =
    \\<!doctype html><meta charset="utf-8"><title>404</title>
    \\<h1>404 — not found</h1><p><a href="/">back to index</a></p>
;

const method_not_allowed = "HTTP/1.0 405 Method Not Allowed\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 22\r\n" ++
    "Allow: GET, HEAD\r\n" ++
    "Connection: close\r\n\r\n" ++
    "405 method not allowed";

/// Build a cached HTTP response: status line, headers and the body.
fn buildResponse(gpa: Allocator, status: []const u8, content_type: []const u8, body: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        "HTTP/1.0 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try w.writeAll(body);
    return aw.toOwnedSlice();
}

// ---- connection handling --------------------------------------------------

/// Handle one connection: read the request line, pick a response, then close.
/// `base` is the site base path (stripped before asset lookups, since assets
/// live at content-relative paths). `gen_id` is non-null only in watch mode,
/// enabling the `/__strike/gen` generation-poll endpoint the reload script
/// fetches.
fn serveConn(gpa: Allocator, io: std.Io, stream: net.Stream, routes: []const Route, assets: ?std.Io.Dir, base: []const u8, not_found: []const u8, gen_id: ?u64) !void {
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    // Parse the request line and resolve the response *before* draining (which
    // would overwrite the buffer the request-line slices point into).
    var path_buf: [1024]u8 = undefined;
    var gen_buf: [128]u8 = undefined;
    const req: ?Request = requestLine(&reader.interface) catch null;
    var response: []const u8 = not_found;
    var owned: ?[]u8 = null; // a per-request asset response, freed after write
    defer if (owned) |o| gpa.free(o);
    var head_only = false;

    if (req) |r| {
        head_only = std.mem.eql(u8, r.method, "HEAD");
        if (!head_only and !std.mem.eql(u8, r.method, "GET")) {
            response = method_not_allowed;
        } else if (normalizePath(&path_buf, r.path)) |p| {
            if (gen_id != null and std.mem.eql(u8, p, "/__strike/gen")) {
                response = genResponse(&gen_buf, gen_id.?);
            } else if (lookupRoute(routes, p)) |cached| {
                response = cached;
            } else if (assets) |dir| {
                // Assets are content-relative: strip the base path first
                // (`/docs/img.png` -> `/img.png`).
                var ap = p;
                if (base.len > 0 and std.mem.startsWith(u8, ap, base) and
                    ap.len > base.len and ap[base.len] == '/')
                {
                    ap = ap[base.len..];
                }
                if (try serveAsset(gpa, io, dir, ap)) |a| {
                    owned = a;
                    response = a;
                }
            }
        } else |_| {}
    }
    drainRequest(&reader.interface) catch {};

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(if (head_only) headersOnly(response) else response);
    try writer.interface.flush();
}

const Request = struct { method: []const u8, path: []const u8 };

/// Read the request line into its method + path tokens. Both slices borrow
/// the reader's buffer; use them before reading further.
fn requestLine(r: *std.Io.Reader) !Request {
    const line = try r.takeDelimiterInclusive('\n');
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return error.BadRequest;
    const path = it.next() orelse return error.BadRequest;
    return .{ .method = method, .path = path };
}

/// Best-effort drain of the remaining request headers so the client reads our
/// reply cleanly (an unread receive buffer at close() can trigger a TCP reset).
fn drainRequest(r: *std.Io.Reader) !void {
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (line.len <= 2) return; // blank line ("\r\n" or "\n") ends the headers
    }
}

/// Normalize a raw request path into `buf`: cut at `?`/`#`, percent-decode,
/// strip one trailing slash (except for `/` itself), reject NUL/empty/too-long.
fn normalizePath(buf: []u8, raw: []const u8) ![]const u8 {
    var p = raw;
    if (std.mem.indexOfAny(u8, p, "?#")) |cut| p = p[0..cut];
    if (p.len == 0) return error.BadPath;
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len) {
        if (n >= buf.len) return error.BadPath;
        var c = p[i];
        if (c == '%' and i + 2 < p.len) {
            c = std.fmt.parseInt(u8, p[i + 1 .. i + 3], 16) catch return error.BadPath;
            i += 3;
        } else {
            i += 1;
        }
        if (c == 0) return error.BadPath;
        buf[n] = c;
        n += 1;
    }
    var out: []const u8 = buf[0..n];
    if (out.len > 1 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    return out;
}

/// The `/__strike/gen` response, written into `buf`: the generation id as
/// plain text, uncacheable, so the reload script sees swaps immediately.
fn genResponse(buf: []u8, id: u64) []const u8 {
    var body_buf: [20]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{d}", .{id}) catch unreachable;
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.0 200 OK\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch unreachable;
}

/// The status line + headers of a prebuilt response (for HEAD).
fn headersOnly(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return response;
    return response[0 .. end + 4];
}

// ---- static assets ----------------------------------------------------------

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

fn mimeFor(path: []const u8) ?[]const u8 {
    for (mime_types) |m| {
        if (std.ascii.endsWithIgnoreCase(path, m.ext)) return m.mime;
    }
    return null;
}

/// Serve a static file from the content dir on a route miss. Only known
/// extensions; `..` and empty segments are rejected. Read per request — a dev
/// server serves fresh bytes, uncached by design. Returns a full HTTP
/// response (caller frees), or null to fall through to 404.
fn serveAsset(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]u8 {
    const mime = mimeFor(path) orelse return null;
    if (path.len < 2 or path[0] != '/') return null;
    const rel = path[1..];
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, "..")) return null;
    }
    const data = dir.readFileAlloc(io, rel, gpa, .limited(64 << 20)) catch return null;
    defer gpa.free(data);
    return try buildResponse(gpa, "200 OK", mime, data);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "buildResponse writes a well-formed HTTP/1.0 response" {
    const resp = try buildResponse(testing.allocator, "200 OK", "text/html; charset=utf-8", "<p>hi</p>");
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.0 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "Content-Type: text/html; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 9\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n<p>hi</p>"));
}

test "requestLine extracts the method and path" {
    var r: std.Io.Reader = .fixed("GET /pchem/quantum HTTP/1.1\r\nHost: x\r\n\r\n");
    const req = try requestLine(&r);
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("/pchem/quantum", req.path);
}

test "requestLine rejects a malformed request line" {
    var r: std.Io.Reader = .fixed("\r\n");
    try testing.expectError(error.BadRequest, requestLine(&r));
}

test "drainRequest stops at the blank line ending the headers" {
    var r: std.Io.Reader = .fixed("Host: x\r\nAccept: */*\r\n\r\nnot part of the request");
    try drainRequest(&r);
    // Only the headers (through the blank line) were consumed.
    try testing.expectEqualStrings("not part of the request", try r.take(23));
}

test "normalizePath strips query strings and trailing slashes and decodes" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings("/pchem", try normalizePath(&buf, "/pchem/?x=1"));
    try testing.expectEqualStrings("/a b", try normalizePath(&buf, "/a%20b"));
    try testing.expectEqualStrings("/", try normalizePath(&buf, "/"));
    try testing.expectEqualStrings("/x", try normalizePath(&buf, "/x#frag"));
    try testing.expectError(error.BadPath, normalizePath(&buf, "/%00"));
    try testing.expectError(error.BadPath, normalizePath(&buf, ""));
}

test "headersOnly cuts a response after the header block" {
    const resp = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    try testing.expectEqualStrings("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n", headersOnly(resp));
}

test "mimeFor knows asset extensions and rejects others" {
    try testing.expectEqualStrings("image/png", mimeFor("/img/cat.PNG").?);
    try testing.expectEqualStrings("text/css", mimeFor("/style.css").?);
    try testing.expect(mimeFor("/doc.md") == null);
    try testing.expect(mimeFor("/no-extension") == null);
}

test "spliceReload injects the script before </body>" {
    const spliced = try spliceReload(testing.allocator, "<html><body><p>x</p></body></html>");
    defer testing.allocator.free(spliced);
    const at = std.mem.indexOf(u8, spliced, shell.reload_script).?;
    try testing.expectEqualStrings("</body></html>", spliced[at + shell.reload_script.len ..]);
    // no </body> -> appended
    const appended = try spliceReload(testing.allocator, "<p>x</p>");
    defer testing.allocator.free(appended);
    try testing.expect(std.mem.endsWith(u8, appended, shell.reload_script));
}

test "genResponse reports the generation id uncached" {
    var buf: [128]u8 = undefined;
    const resp = genResponse(&buf, 7);
    try testing.expect(std.mem.indexOf(u8, resp, "Cache-Control: no-store\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n7"));
}

test "fingerprint is deterministic and moves when a file changes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "p");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "p/a.md", .data = "# A\n" });

    var h1 = std.hash.Wyhash.init(0);
    hashDir(testing.io, &h1, tmp.dir);
    var h2 = std.hash.Wyhash.init(0);
    hashDir(testing.io, &h2, tmp.dir);
    try testing.expectEqual(h1.final(), h2.final());

    // a size change definitely moves the hash (mtime alone may be too coarse
    // within one test's timespan)
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "p/a.md", .data = "# A\nmore\n" });
    var h3 = std.hash.Wyhash.init(0);
    hashDir(testing.io, &h3, tmp.dir);
    try testing.expect(h1.final() != h3.final());
}
