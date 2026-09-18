//! A small, build-time theme file format. A theme names one fixed palette;
//! the shell inlines its validated declarations into exported HTML.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ThemeFile = struct {
    label: []const u8,
    css: []const u8,
};

const keys = [_][]const u8{
    "color-scheme", "--bg",     "--fg",                 "--muted",            "--accent",          "--warn",
    "--code-bg",    "--border", "--collapse-closed-bg", "--collapse-open-bg", "--collapse-shadow", "--collapse-closed-shadow",
    "--sidebar-bg",
};

pub fn load(io: std.Io, arena: Allocator, dir: std.Io.Dir, path: []const u8) !ThemeFile {
    const src = try dir.readFileAlloc(io, path, arena, .limited(16 << 10));
    return parse(arena, src);
}

pub fn parse(arena: Allocator, src: []const u8) !ThemeFile {
    var values: [keys.len]?[]const u8 = @splat(null);
    var label: []const u8 = "Custom";
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidThemeFile;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "label")) {
            if (value.len == 0 or value.len > 40) return error.InvalidThemeFile;
            label = value;
            continue;
        }
        var found = false;
        for (keys, 0..) |known, i| {
            if (!std.mem.eql(u8, key, known)) continue;
            found = true;
            if (!safeValue(value)) return error.InvalidThemeFile;
            if (i == 0 and !std.mem.eql(u8, value, "light") and !std.mem.eql(u8, value, "dark")) return error.InvalidThemeFile;
            values[i] = value;
            break;
        }
        if (!found) return error.InvalidThemeFile;
    }
    var css: std.ArrayList(u8) = .empty;
    for (keys, 0..) |key, i| {
        const value = values[i] orelse return error.IncompleteThemeFile;
        try css.appendSlice(arena, key);
        try css.append(arena, ':');
        try css.appendSlice(arena, value);
        try css.append(arena, ';');
    }
    return .{ .label = label, .css = try css.toOwnedSlice(arena) };
}

fn safeValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            ' ', '#', '-', '_', '.', ',', '(', ')', '%', '/' => {},
            else => return false,
        }
    }
    return true;
}

test "theme file requires a complete safe palette" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const theme = try parse(a,
        \\label: Paper Ink
        \\color-scheme: dark
        \\--bg: #101010
        \\--fg: #eeeeee
        \\--muted: #999999
        \\--accent: #77aaff
        \\--warn: #ffaa66
        \\--code-bg: rgba(255,255,255,.08)
        \\--border: #333333
        \\--collapse-closed-bg: #222222
        \\--collapse-open-bg: var(--bg)
        \\--collapse-shadow: none
        \\--collapse-closed-shadow: none
        \\--sidebar-bg: #080808
    );
    try std.testing.expectEqualStrings("Paper Ink", theme.label);
    try std.testing.expect(std.mem.indexOf(u8, theme.css, "--bg:#101010;") != null);
    try std.testing.expectError(error.IncompleteThemeFile, parse(a, "label: Only a name"));
    try std.testing.expectError(error.InvalidThemeFile, parse(a, "--bg: </style>"));
}

test "theme file rejects an unrecognized color-scheme value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidThemeFile, parse(a, "color-scheme: system\n--bg: #fff"));
}

test "theme file rejects an unknown key instead of ignoring it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidThemeFile, parse(a, "color-scheme: light\n--made-up: #fff"));
}

test "theme file rejects an over-long label" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const long_label = "label: " ++ "x" ** 41;
    try std.testing.expectError(error.InvalidThemeFile, parse(a, long_label));
}

test "theme file accepts var() and rgba() values, skips comments and blank lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const theme = try parse(a,
        \\# a comment line, and a blank line follow
        \\
        \\label: Vars
        \\color-scheme: light
        \\--bg: #fff
        \\--fg: #000
        \\--muted: #999
        \\--accent: #06c
        \\--warn: #c60
        \\--code-bg: rgba(0,0,0,.08)
        \\--border: #ddd
        \\--collapse-closed-bg: #eee
        \\--collapse-open-bg: var(--bg)
        \\--collapse-shadow: none
        \\--collapse-closed-shadow: none
        \\--sidebar-bg: #f5f5f5
    );
    try std.testing.expect(std.mem.indexOf(u8, theme.css, "rgba(0,0,0,.08)") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme.css, "var(--bg)") != null);
}
