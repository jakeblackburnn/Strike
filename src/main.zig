//! `strike` — the CLI for the strikedown markdown/`.sx` renderer.
//!
//! Subcommands (`usage()` below is the authoritative flag list):
//!   strike serve  [dir|file]   Serve a content dir (or one .md/.sx file) over HTTP.
//!   strike render <file>       Render a single .md/.sx file to HTML.
//!   strike build  [dir]        Export a content directory to static HTML.
//!   strike init   [dir]        Scaffold a starter strike.yaml.
//!
//! `serve`'s HTTP server itself lives in `server.zig`; `build` renders through
//! the same `site.renderAll`/`site.outPath` pipeline `serve` does, so the
//! static export and the live preview can't drift.

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
    // Every subcommand below allocates-and-uses-once, the same
    // "process-lifetime, never free piecemeal" contract `project.load`
    // documents — `init.arena` (freed automatically on exit) matches that
    // contract, instead of tripping `init.gpa`'s leak checker on every run.
    // The one exception: `serve --watch` rebuilds the site repeatedly, so its
    // per-generation arenas are backed by `init.gpa` and freed on every swap.
    const arena = init.arena.allocator();

    var args = try std.process.Args.iterateAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.next(); // argv[0]: the executable path

    const cmd = args.next() orelse return usage();
    if (std.mem.eql(u8, cmd, "serve")) return cmdServe(arena, init.gpa, io, &args) catch |err| fail(cmd, err);
    if (std.mem.eql(u8, cmd, "render")) return cmdRender(arena, io, &args) catch |err| fail(cmd, err);
    if (std.mem.eql(u8, cmd, "build")) return cmdBuild(arena, io, &args) catch |err| fail(cmd, err);
    if (std.mem.eql(u8, cmd, "init")) return cmdInit(io, &args) catch |err| fail(cmd, err);
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return usage();

    std.debug.print("strike: unknown command '{s}'\n\n", .{cmd});
    usage();
    std.process.exit(1);
}

/// One friendly line + exit 1 instead of a raw error return trace — flag
/// mistakes additionally reprint the usage text.
fn fail(cmd: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.UnknownFlag, error.MissingValue, error.UnexpectedArgument, error.MissingFile, error.InvalidCharacter, error.Overflow => {
            std.debug.print("strike {s}: {s}\n\n", .{ cmd, switch (err) {
                error.UnknownFlag => "unknown flag",
                error.MissingValue => "a flag is missing its value",
                error.UnexpectedArgument => "too many arguments",
                error.MissingFile => "a file argument is required",
                else => "a flag value doesn't parse",
            } });
            usage();
        },
        else => std.debug.print("strike {s}: {s}\n", .{ cmd, @errorName(err) }),
    }
    std.process.exit(1);
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
        \\Defaults: dir "." for serve/build/init; host {s}; port {d}; outdir "html".
        \\A dir's strike.yaml `serve:` map (watch/open/host/port) fills unset serve flags.
        \\
    , .{ default_host, default_port });
}

const default_host = "127.0.0.1";
const default_port: u16 = 8080;

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
        .host = parsed.host orelse serve_cfg.getScalar("host") orelse default_host,
        .port = parsed.port orelse blk: {
            const s = serve_cfg.getScalar("port") orelse break :blk default_port;
            break :blk std.fmt.parseInt(u16, s, 10) catch default_port;
        },
        .watch = parsed.watch orelse yamlBool(serve_cfg, "watch"),
        .open = parsed.open orelse yamlBool(serve_cfg, "open"),
    };
}

/// Fail-soft yaml boolean: the usual spellings of yes (any casing) are true,
/// everything else — including typos — is false.
fn yamlBool(cfg: yaml.Value, key: []const u8) bool {
    const s = cfg.getScalar(key) orelse return false;
    for ([_][]const u8{ "true", "yes", "on", "1" }) |t| {
        if (std.ascii.eqlIgnoreCase(s, t)) return true;
    }
    return false;
}

/// The value token following a `--flag`. A `-`-leading token is another
/// flag, not a value — `--host --watch` fails loudly instead of silently
/// binding "--watch" as the host.
fn flagValue(args: anytype) ![]const u8 {
    const v = args.next() orelse return error.MissingValue;
    if (std.mem.startsWith(u8, v, "-")) return error.MissingValue;
    return v;
}

/// Parse `serve`'s flags from any iterator exposing `next() ?[:0]const u8` (or
/// `?[]const u8`) — `std.process.Args.Iterator` in production, a plain slice
/// in tests.
fn parseServeArgs(args: anytype) !ServeArgs {
    var parsed: ServeArgs = .{};
    var have_dir = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--port")) {
            parsed.port = try std.fmt.parseInt(u16, try flagValue(args), 10);
        } else if (std.mem.eql(u8, a, "--host")) {
            parsed.host = try flagValue(args);
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
            parsed.out = try flagValue(args);
        } else if (std.mem.eql(u8, a, "--fragment")) {
            parsed.fragment = true;
        } else if (std.mem.eql(u8, a, "--header")) {
            parsed.header = try flagValue(args);
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
fn cmdRender(arena: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseRenderArgs(args);
    const path = parsed.path orelse return error.MissingFile;

    const base: sheet.Sheet = if (parsed.header) |hp|
        try sheet.load(io, arena, std.Io.Dir.cwd(), hp)
    else
        .empty;
    const md = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(project.max_doc_bytes));
    const html = try renderStandalone(arena, md, path, parsed.fragment, base);

    if (parsed.out) |op| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = html });
    } else {
        try writeStdout(io, html);
    }
}

/// The pure middle of `cmdRender`: one document's HTML, as a bare fragment or
/// wrapped in the standalone shell (title from the first heading, else the
/// prettified filename).
fn renderStandalone(arena: std.mem.Allocator, md: []const u8, path: []const u8, fragment: bool, base: sheet.Sheet) ![]u8 {
    const body = (try render_html.render(arena, md, .{ .sheet = base })).takeHtml(arena, path);
    if (fragment) return body;
    const title = project.firstHeading(md) orelse
        try project.prettify(arena, project.stripExtension(std.fs.path.basename(path)));
    return shell.wrapPage(arena, shell.standalone(title), body);
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
            parsed.out_dir = try flagValue(args);
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else if (!have_dir) {
            parsed.dir = a;
            have_dir = true;
        } else return error.UnexpectedArgument;
    }
    return parsed;
}

/// Static-export `dir` to `out_dir` through the same
/// `site.renderAll`/`site.outPath` pipeline `serve` renders with. This is the
/// only static export there is — `zig build` only compiles the CLI.
fn cmdBuild(arena: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseBuildArgs(args);

    var content = try std.Io.Dir.cwd().openDir(io, parsed.dir, .{ .iterate = true });
    defer content.close(io);
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, parsed.out_dir, .{});
    defer out.close(io);

    const count = try exportSite(arena, io, content, out);
    std.debug.print("strike build: rendered {d} page(s) to {s}/\n", .{ count, parsed.out_dir });
}

/// The dir-to-dir middle of `cmdBuild`: load `content`, render every page,
/// write the export tree into `out`. Returns the page count.
fn exportSite(arena: std.mem.Allocator, io: std.Io, content: std.Io.Dir, out: std.Io.Dir) !usize {
    const loaded = try project.load(io, arena, content);
    const pages = try site.renderAll(arena, loaded);
    for (pages) |p| {
        const rel = try site.outPath(arena, p, loaded.base);
        if (std.fs.path.dirname(rel)) |d| try out.createDirPath(io, d);
        try out.writeFile(io, .{ .sub_path = rel, .data = p.html });
    }
    return pages.len;
}

// ---- init -------------------------------------------------------------------

// A starting point, not a full key list: the commented lines are the keys worth
// knowing about on day one. `docs/reference/STRIKE_YAML.md` is the complete
// reference, and the scaffold deliberately stays shorter than it.
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
    if (try writeScaffold(io, dir, parsed.site_level)) {
        std.debug.print("wrote {s}/strike.yaml\n", .{parsed.dir});
        return;
    }
    // The refusal is its own complete message — exit directly rather than
    // returning an error `fail` would report a second time.
    std.debug.print("strike init: {s}/strike.yaml already exists\n", .{parsed.dir});
    std.process.exit(1);
}

/// Write the scaffold into `dir` unless a strike.yaml already exists there
/// (never overwrite). True when written.
fn writeScaffold(io: std.Io, dir: std.Io.Dir, site_level: bool) !bool {
    dir.access(io, "strike.yaml", .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        try dir.writeFile(io, .{
            .sub_path = "strike.yaml",
            .data = if (site_level) site_yaml_template else project_yaml_template,
        });
        return true;
    };
    return false;
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


// ---- v0.1.0 fixes ------------------------------------------------------------

test "yamlBool accepts the usual spellings of yes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try yaml.parse(arena.allocator(), "a: true\nb: Yes\nc: ON\nd: 1\ne: flase\nf: false");
    try testing.expect(yamlBool(cfg, "a"));
    try testing.expect(yamlBool(cfg, "b"));
    try testing.expect(yamlBool(cfg, "c"));
    try testing.expect(yamlBool(cfg, "d"));
    try testing.expect(!yamlBool(cfg, "e"));
    try testing.expect(!yamlBool(cfg, "f"));
    try testing.expect(!yamlBool(cfg, "missing"));
}

test "a flag value may not itself be a flag" {
    var args: SliceArgs = .{ .items = &.{ "--host", "--watch" } };
    try testing.expectError(error.MissingValue, parseServeArgs(&args));
    var args2: SliceArgs = .{ .items = &.{ "-o", "--fragment", "x.md" } };
    try testing.expectError(error.MissingValue, parseRenderArgs(&args2));
}

test "writeScaffold writes once and refuses to overwrite" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(try writeScaffold(testing.io, tmp.dir, false));
    const first = try tmp.dir.readFileAlloc(testing.io, "strike.yaml", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "title: My Project") != null);
    // second run: refused, file untouched
    try testing.expect(!(try writeScaffold(testing.io, tmp.dir, true)));
    const second = try tmp.dir.readFileAlloc(testing.io, "strike.yaml", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "writeScaffold --site writes the site template" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(try writeScaffold(testing.io, tmp.dir, true));
    const data = try tmp.dir.readFileAlloc(testing.io, "strike.yaml", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "# base: /docs") != null);
}

test "renderStandalone: fragment vs wrapped, title fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frag = try renderStandalone(a, "# T\n\nbody", "x.md", true, .empty);
    try testing.expectEqualStrings("<h1 id=\"t\">T</h1>\n<p>body</p>\n", frag);
    // wrapped: full page, title from the heading
    const page = try renderStandalone(a, "# My Title\n\nbody", "x.md", false, .empty);
    try testing.expect(std.mem.indexOf(u8, page, "<title>My Title</title>") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<p>body</p>") != null);
    // no heading: the prettified filename is the title
    const named = try renderStandalone(a, "just prose", "notes/02_lab-report.md", false, .empty);
    try testing.expect(std.mem.indexOf(u8, named, "<title>Lab Report</title>") != null);
}

test "exportSite writes the same tree serve routes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "content/blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "content/blog/post.md", .data = "# Post\nbody" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "content/blog/main.md", .data = "# Blog Home" });
    try tmp.dir.createDirPath(testing.io, "out");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var content = try tmp.dir.openDir(testing.io, "content", .{ .iterate = true });
    defer content.close(testing.io);
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);

    const count = try exportSite(arena.allocator(), testing.io, content, out);
    try testing.expectEqual(@as(usize, 3), count); // picker + project home + doc
    const picker = try tmp.dir.readFileAlloc(testing.io, "out/index.html", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(picker);
    try testing.expect(std.mem.indexOf(u8, picker, "href=\"/blog\"") != null);
    const home = try tmp.dir.readFileAlloc(testing.io, "out/blog/index.html", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(home);
    try testing.expect(std.mem.indexOf(u8, home, "Blog Home") != null);
    const doc = try tmp.dir.readFileAlloc(testing.io, "out/blog/post.html", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "<h1 id=\"post\">Post</h1>") != null);
}
