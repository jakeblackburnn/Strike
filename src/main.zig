//! `strike` — the CLI for the strikedown markdown/`.sx` renderer.
//!
//! Subcommands:
//!   strike serve  [dir|file] [--host HOST] [--port PORT] [--watch]
//!                                                     Serve a content dir (or one .md/.sx file) over HTTP.
//!   strike render <file> [-o out.html] [--fragment]   Render a single .md/.sx file to HTML.
//!   strike build  [dir] [-o outdir]                   Export a content directory to static HTML.
//!   strike init   [dir] [--site]                      Scaffold a starter strike.yaml.
//!
//! `serve`'s HTTP server itself lives in `server.zig`; `build` shares the
//! exact same `site.renderAll`/`site.outPath` pipeline `build.zig`'s comptime
//! static export uses, so the two can't drift.

const std = @import("std");
const project = @import("project.zig");
const site = @import("site.zig");
const shell = @import("shell.zig");
const render_html = @import("render_html.zig");
const sheet = @import("sheet.zig");
const server = @import("server.zig");
const yaml = @import("yaml.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Every subcommand below allocates-and-uses-once, the same "process- or
    // build-lifetime, never free piecemeal" contract `project.load` already
    // documents — `init.arena` (freed automatically on exit) matches that
    // contract, instead of tripping `init.gpa`'s leak checker on every run.
    // The one exception: `serve --watch` rebuilds the site repeatedly, so its
    // per-generation arenas are backed by `init.gpa` and freed on every swap.
    const gpa = init.arena.allocator();

    var args = try std.process.Args.iterateAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]: the executable path

    const cmd = args.next() orelse return usage();
    if (std.mem.eql(u8, cmd, "serve")) return cmdServe(gpa, init.gpa, io, &args);
    if (std.mem.eql(u8, cmd, "render")) return cmdRender(gpa, io, &args);
    if (std.mem.eql(u8, cmd, "build")) return cmdBuild(gpa, io, &args);
    if (std.mem.eql(u8, cmd, "init")) return cmdInit(io, &args);
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return usage();

    std.debug.print("strike: unknown command '{s}'\n\n", .{cmd});
    usage();
    return error.UnknownCommand;
}

fn usage() void {
    std.debug.print(
        \\strike -- render and serve strikedown (markdown/.sx) content.
        \\
        \\Usage:
        \\  strike serve  [dir|file] [--host HOST] [--port PORT] [--[no-]watch] [--[no-]open]
        \\                                                    Serve a content dir (or one .md/.sx file) over HTTP;
        \\                                                    --watch re-renders on change and auto-reloads the browser;
        \\                                                    --open opens the front page in the default browser.
        \\  strike render <file> [-o out.html] [--fragment] [--header f.sxh]
        \\                                                    Render a single .md/.sx file to HTML.
        \\  strike build  [dir] [-o outdir]                   Export a content directory to static HTML.
        \\  strike init   [dir] [--site]                      Scaffold a starter strike.yaml.
        \\
        \\Defaults: dir "." for serve/build/init; host 127.0.0.1; port 8080; outdir "html".
        \\A dir's strike.yaml `serve:` map (watch/open/host/port) fills unset serve flags.
        \\
    , .{});
}

// ---- serve ------------------------------------------------------------------

/// `serve`'s flags as given: `null` means "flag not passed", so yaml serve
/// defaults can fill it before `resolveServe` applies the built-in defaults.
const ServeArgs = struct {
    dir: []const u8 = ".",
    host: ?[]const u8 = null,
    port: ?u16 = null,
    watch: ?bool = null,
    open: ?bool = null,
};

/// Fully resolved serve options: flags beat the yaml `serve:` map, which
/// beats the built-in defaults. Yaml values that don't parse are ignored
/// (fail-soft, like the rest of the config handling).
const ServeOpts = struct {
    host: []const u8,
    port: u16,
    watch: bool,
    open: bool,
};

fn resolveServe(parsed: ServeArgs, cfg: yaml.Value) ServeOpts {
    const serve_cfg = cfg.get("serve") orelse yaml.Value{ .map = &.{} };
    return .{
        .host = parsed.host orelse serve_cfg.getScalar("host") orelse "127.0.0.1",
        .port = parsed.port orelse blk: {
            const s = serve_cfg.getScalar("port") orelse break :blk 8080;
            break :blk std.fmt.parseInt(u16, s, 10) catch 8080;
        },
        .watch = parsed.watch orelse yamlBool(serve_cfg, "watch"),
        .open = parsed.open orelse yamlBool(serve_cfg, "open"),
    };
}

fn yamlBool(cfg: yaml.Value, key: []const u8) bool {
    const s = cfg.getScalar(key) orelse return false;
    return std.mem.eql(u8, s, "true");
}

/// Parse `serve`'s flags from any iterator exposing `next() ?[:0]const u8` (or
/// `?[]const u8`) — `std.process.Args.Iterator` in production, a plain slice
/// in tests.
fn parseServeArgs(args: anytype) !ServeArgs {
    var parsed: ServeArgs = .{};
    var have_dir = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--port")) {
            parsed.port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--host")) {
            parsed.host = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--watch")) {
            parsed.watch = true;
        } else if (std.mem.eql(u8, a, "--no-watch")) {
            parsed.watch = false;
        } else if (std.mem.eql(u8, a, "--open")) {
            parsed.open = true;
        } else if (std.mem.eql(u8, a, "--no-open")) {
            parsed.open = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag; // never mistake a typoed flag for the target dir
        } else if (!have_dir) {
            parsed.dir = a;
            have_dir = true;
        } else return error.UnexpectedArgument;
    }
    return parsed;
}

/// Classify the target (dir vs single .md/.sx file) and hand off to
/// `server.run`, which owns the socket loop and route table.
fn cmdServe(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseServeArgs(args);
    const target = server.classifyTarget(io, parsed.dir);
    // Dir targets may carry serve defaults in their strike.yaml; explicit
    // flags always beat them. Single-file targets have no config to read.
    const cfg: yaml.Value = switch (target) {
        .dir => |d| blk: {
            const dir = std.Io.Dir.cwd().openDir(io, d, .{}) catch break :blk .{ .map = &.{} };
            break :blk project.readConfig(io, arena, dir, "strike.yaml");
        },
        .file => .{ .map = &.{} },
    };
    const opts = resolveServe(parsed, cfg);
    try server.run(arena, gpa, io, .{
        .target = target,
        .host = opts.host,
        .port = opts.port,
        .watch = opts.watch,
        .open = opts.open,
    });
}

// ---- render -------------------------------------------------------------

const RenderArgs = struct { path: ?[]const u8 = null, out: ?[]const u8 = null, fragment: bool = false, header: ?[]const u8 = null };

fn parseRenderArgs(args: anytype) !RenderArgs {
    var parsed: RenderArgs = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-o")) {
            parsed.out = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--fragment")) {
            parsed.fragment = true;
        } else if (std.mem.eql(u8, a, "--header")) {
            parsed.header = args.next() orelse return error.MissingValue;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else if (parsed.path == null) {
            parsed.path = a;
        } else return error.UnexpectedArgument;
    }
    return parsed;
}

/// Render a single file, standalone (no project/site context). `--fragment`
/// emits just the markdown body — the hook for embedding strike's output in
/// another pipeline; otherwise the fragment is wrapped in `shell.standalone`.
/// `--header` seeds the document with a `.sxh` typography sheet, standing in
/// for the `strike.yaml` `header:` a project would provide. Unlike the
/// fail-soft project path, an explicitly named header that can't be read is
/// an error — the user asked for it by name.
fn cmdRender(gpa: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseRenderArgs(args);
    const path = parsed.path orelse return error.MissingFile;

    const base: sheet.Sheet = if (parsed.header) |hp|
        try sheet.load(io, gpa, std.Io.Dir.cwd(), hp)
    else
        .empty;
    const md = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    const body = try render_html.render(gpa, md, .{ .sheet = base });

    const html = if (parsed.fragment) body else blk: {
        const title = project.firstHeading(md) orelse
            try project.prettify(gpa, project.stripExtension(std.fs.path.basename(path)));
        break :blk try shell.wrapPage(gpa, shell.standalone(title), body);
    };

    if (parsed.out) |op| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = html });
    } else {
        try writeStdout(io, html);
    }
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

// ---- build ------------------------------------------------------------------

const BuildArgs = struct { dir: []const u8 = ".", out_dir: []const u8 = "html" };

fn parseBuildArgs(args: anytype) !BuildArgs {
    var parsed: BuildArgs = .{};
    var have_dir = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-o")) {
            parsed.out_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else if (!have_dir) {
            parsed.dir = a;
            have_dir = true;
        } else return error.UnexpectedArgument;
    }
    return parsed;
}

/// Static-export `dir` to `out_dir`, sharing `site.renderAll`/`site.outPath`
/// with `build.zig`'s comptime export — the CLI equivalent of `zig build`,
/// usable without a Zig toolchain once `strike` is installed.
fn cmdBuild(gpa: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseBuildArgs(args);

    var content = try std.Io.Dir.cwd().openDir(io, parsed.dir, .{ .iterate = true });
    defer content.close(io);
    const loaded = try project.load(io, gpa, content);
    const pages = try site.renderAll(gpa, loaded);

    var out = try std.Io.Dir.cwd().createDirPathOpen(io, parsed.out_dir, .{});
    defer out.close(io);

    for (pages) |p| {
        const rel = try site.outPath(gpa, p, loaded.base);
        if (std.fs.path.dirname(rel)) |d| try out.createDirPath(io, d);
        try out.writeFile(io, .{ .sub_path = rel, .data = p.html });
    }
    std.debug.print("strike build: rendered {d} page(s) to {s}/\n", .{ pages.len, parsed.out_dir });
}

// ---- init -------------------------------------------------------------------

// Mirrors STRIKE_YAML.md's own example blocks, so the scaffold and the docs
// stay in sync by construction.
const project_yaml_template =
    \\title: My Project
    \\description: ""
    \\# home: index.md
    \\# header: theme.sxh  # typography header (.sxh) layered over the site one
    \\# labels:
    \\#   index.md: Home
    \\# order:
    \\#   - index.md
    \\# hidden: []
    \\
;
const site_yaml_template =
    \\title: strikedown
    \\# repo: https://github.com/you/strike
    \\# theme: winter evening  # season (fall|winter|spring|summer) and/or time (morning|evening)
    \\# width: 44
    \\# base: /docs        # mount the site under a subpath of an existing website
    \\# header: theme.sxh  # typography header (.sxh) applied to every project
    \\# projects:
    \\#   - my_project
    \\
;

const InitArgs = struct { dir: []const u8 = ".", site_level: bool = false };

fn parseInitArgs(args: anytype) !InitArgs {
    var parsed: InitArgs = .{};
    var have_dir = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--site")) {
            parsed.site_level = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else if (!have_dir) {
            parsed.dir = a;
            have_dir = true;
        } else return error.UnexpectedArgument;
    }
    return parsed;
}

/// Scaffold a new `strike.yaml` in `dir` from an embedded template; refuses to
/// overwrite an existing one. Round-trip editing of an existing file (e.g. a
/// future `strike config set`) is a deliberately unbuilt, documented gap — see
/// CLAUDE.md — since `yaml.zig`'s parser discards comments/formatting and
/// can't faithfully write a file back out.
fn cmdInit(io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseInitArgs(args);

    var dir = try std.Io.Dir.cwd().openDir(io, parsed.dir, .{});
    defer dir.close(io);
    dir.access(io, "strike.yaml", .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        try dir.writeFile(io, .{
            .sub_path = "strike.yaml",
            .data = if (parsed.site_level) site_yaml_template else project_yaml_template,
        });
        return std.debug.print("wrote {s}/strike.yaml\n", .{parsed.dir});
    };
    std.debug.print("strike init: {s}/strike.yaml already exists\n", .{parsed.dir});
    return error.AlreadyExists;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

/// A plain-slice stand-in for `std.process.Args.Iterator` so flag-parsing can
/// be tested without fabricating a real argv vector.
const SliceArgs = struct {
    items: []const []const u8,
    i: usize = 0,

    fn next(self: *SliceArgs) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

test "parseServeArgs leaves unset flags null and parses flags in any order" {
    var none: SliceArgs = .{ .items = &.{} };
    const defaults = try parseServeArgs(&none);
    try testing.expectEqualStrings(".", defaults.dir);
    try testing.expectEqual(@as(?[]const u8, null), defaults.host);
    try testing.expectEqual(@as(?u16, null), defaults.port);
    try testing.expectEqual(@as(?bool, null), defaults.watch);
    try testing.expectEqual(@as(?bool, null), defaults.open);

    var full: SliceArgs = .{ .items = &.{ "--port", "9000", "docs", "--host", "0.0.0.0", "--watch", "--open" } };
    const parsed = try parseServeArgs(&full);
    try testing.expectEqualStrings("docs", parsed.dir);
    try testing.expectEqualStrings("0.0.0.0", parsed.host.?);
    try testing.expectEqual(@as(u16, 9000), parsed.port.?);
    try testing.expect(parsed.watch.?);
    try testing.expect(parsed.open.?);

    var negated: SliceArgs = .{ .items = &.{ "--no-watch", "--no-open" } };
    const off = try parseServeArgs(&negated);
    try testing.expect(!off.watch.?);
    try testing.expect(!off.open.?);
}

test "resolveServe: flags beat yaml serve: which beats built-in defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const cfg = try yaml.parse(gpa,
        \\serve:
        \\  watch: true
        \\  open: true
        \\  host: 0.0.0.0
        \\  port: 9999
    );

    // No flags: yaml fills everything.
    const from_yaml = resolveServe(.{}, cfg);
    try testing.expectEqualStrings("0.0.0.0", from_yaml.host);
    try testing.expectEqual(@as(u16, 9999), from_yaml.port);
    try testing.expect(from_yaml.watch);
    try testing.expect(from_yaml.open);

    // Flags win over yaml.
    const from_flags = resolveServe(.{ .port = 8000, .watch = false }, cfg);
    try testing.expectEqual(@as(u16, 8000), from_flags.port);
    try testing.expect(!from_flags.watch);
    try testing.expect(from_flags.open);

    // No yaml serve: map -> built-in defaults.
    const builtin = resolveServe(.{}, .{ .map = &.{} });
    try testing.expectEqualStrings("127.0.0.1", builtin.host);
    try testing.expectEqual(@as(u16, 8080), builtin.port);
    try testing.expect(!builtin.watch);
    try testing.expect(!builtin.open);

    // Malformed yaml port is ignored (fail-soft).
    const bad = try yaml.parse(gpa,
        \\serve:
        \\  port: lots
    );
    try testing.expectEqual(@as(u16, 8080), resolveServe(.{}, bad).port);
}

test "parseServeArgs rejects a non-numeric port and a second positional" {
    var bad_port: SliceArgs = .{ .items = &.{ "--port", "abc" } };
    try testing.expectError(error.InvalidCharacter, parseServeArgs(&bad_port));

    var two_dirs: SliceArgs = .{ .items = &.{ "a", "b" } };
    try testing.expectError(error.UnexpectedArgument, parseServeArgs(&two_dirs));
}

test "all parsers reject unknown flags instead of taking them as the target" {
    var serve_typo: SliceArgs = .{ .items = &.{ "--prot", "9000" } };
    try testing.expectError(error.UnknownFlag, parseServeArgs(&serve_typo));

    var render_typo: SliceArgs = .{ .items = &.{ "notes.md", "--fragmnet" } };
    try testing.expectError(error.UnknownFlag, parseRenderArgs(&render_typo));

    var build_typo: SliceArgs = .{ .items = &.{"--out"} };
    try testing.expectError(error.UnknownFlag, parseBuildArgs(&build_typo));

    var init_typo: SliceArgs = .{ .items = &.{"--stie"} };
    try testing.expectError(error.UnknownFlag, parseInitArgs(&init_typo));
}

test "parseRenderArgs and parseServeArgs report missing flag values" {
    var no_out: SliceArgs = .{ .items = &.{ "notes.md", "-o" } };
    try testing.expectError(error.MissingValue, parseRenderArgs(&no_out));

    var no_host: SliceArgs = .{ .items = &.{"--host"} };
    try testing.expectError(error.MissingValue, parseServeArgs(&no_host));
}

test "parseRenderArgs parses the file, -o, --fragment, and --header" {
    var args: SliceArgs = .{ .items = &.{ "notes.md", "-o", "out.html", "--fragment", "--header", "theme.sxh" } };
    const parsed = try parseRenderArgs(&args);
    try testing.expectEqualStrings("notes.md", parsed.path.?);
    try testing.expectEqualStrings("out.html", parsed.out.?);
    try testing.expect(parsed.fragment);
    try testing.expectEqualStrings("theme.sxh", parsed.header.?);

    var no_header: SliceArgs = .{ .items = &.{"notes.md"} };
    try testing.expect((try parseRenderArgs(&no_header)).header == null);
}

test "parseBuildArgs and parseInitArgs apply defaults" {
    var build_none: SliceArgs = .{ .items = &.{} };
    const b = try parseBuildArgs(&build_none);
    try testing.expectEqualStrings(".", b.dir);
    try testing.expectEqualStrings("html", b.out_dir);

    var init_site: SliceArgs = .{ .items = &.{"--site"} };
    const i = try parseInitArgs(&init_site);
    try testing.expectEqualStrings(".", i.dir);
    try testing.expect(i.site_level);
}

