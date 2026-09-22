//! `strike` — the CLI for the strikedown markdown renderer.
//!
//! One subcommand at v0.0.1 (`usage()` below is the authoritative flag
//! list):
//!   strike render <file>   Render a single .md file to HTML.
//!
//! `serve`/`build`/`init` are backlog (`dev/terms.md`) — no server, no site
//! scanning, no static export yet.

const std = @import("std");
const emit_html = @import("emit_html.zig");

const max_doc_bytes = 8 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The one subcommand allocates-and-uses-once, so `init.arena`
    // (process-lifetime, freed on exit) is the right allocator — never
    // freed piecemeal (see `dev/terms.md`, "arena ownership").
    const arena = init.arena.allocator();

    var args = try std.process.Args.iterateAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.next(); // argv[0]

    const cmd = args.next() orelse return usage();
    if (std.mem.eql(u8, cmd, "render")) return cmdRender(arena, io, &args) catch |err| fail(cmd, err);
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return usage();

    std.debug.print("strike: unknown command '{s}'\n\n", .{cmd});
    usage();
    std.process.exit(1);
}

fn fail(cmd: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.UnknownFlag, error.MissingValue, error.UnexpectedArgument, error.MissingFile => {
            std.debug.print("strike {s}: {s}\n\n", .{ cmd, switch (err) {
                error.UnknownFlag => "unknown flag",
                error.MissingValue => "a flag is missing its value",
                error.UnexpectedArgument => "too many arguments",
                error.MissingFile => "a file argument is required",
                else => unreachable,
            } });
            usage();
        },
        else => std.debug.print("strike {s}: {s}\n", .{ cmd, @errorName(err) }),
    }
    std.process.exit(1);
}

fn usage() void {
    std.debug.print(
        \\strike -- render strikedown markdown to HTML.
        \\
        \\Usage:
        \\  strike render <file> [-o out.html] [--fragment]
        \\                                    Render a single .md file to HTML.
        \\
    , .{});
}

const RenderArgs = struct {
    path: ?[]const u8 = null,
    out: ?[]const u8 = null,
    fragment: bool = false,
};

fn parseRenderArgs(args: anytype) !RenderArgs {
    var parsed: RenderArgs = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-o")) {
            parsed.out = try flagValue(args);
        } else if (std.mem.eql(u8, a, "--fragment")) {
            parsed.fragment = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else if (parsed.path == null) {
            parsed.path = a;
        } else return error.UnexpectedArgument;
    }
    return parsed;
}

/// The value token following a `-o` flag. A `-`-leading token is another
/// flag, not a value.
fn flagValue(args: anytype) ![]const u8 {
    const v = args.next() orelse return error.MissingValue;
    if (std.mem.startsWith(u8, v, "-")) return error.MissingValue;
    return v;
}

fn cmdRender(arena: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const parsed = try parseRenderArgs(args);
    const path = parsed.path orelse return error.MissingFile;

    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_doc_bytes));
    const html_out = try emit_html.render(arena, src, .{ .title = path, .fragment = parsed.fragment });

    if (parsed.out) |op| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = html_out });
    } else {
        try writeStdout(io, html_out);
    }
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
