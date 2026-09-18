//! Built-in reader palettes. Add a palette here or load a project theme file.

const std = @import("std");

// The theme palette table: each row is a full set of the 13 CSS
// declarations the reader stylesheet keys off. Four rows are seasonal — a
// "morning" (light) and "evening" (dark) token set apiece, picked by the
// existing light/dark split — and two (`kanagawa`, `vanta-black`) are fixed
// dark palettes with no time variant, so their morning and evening slots
// repeat the same tokens: picking a time for them is a harmless no-op, since
// day/night has no meaning for a palette that never changes. `data-season`
// keeps its historical name (shell.zig's CSS selectors still read it) even
// though it now names "which palette", not literally a season.
//
// Winter is the default palette, so its tokens also fill the bare `:root`
// rules (pages with no attributes set — JS disabled, static export before
// the bootstrap runs).
pub const Palette = struct {
    color_scheme: []const u8,
    bg: []const u8,
    fg: []const u8,
    muted: []const u8,
    accent: []const u8,
    warn: []const u8,
    code_bg: []const u8,
    border: []const u8,
    collapse_closed_bg: []const u8,
    collapse_open_bg: []const u8,
    collapse_shadow: []const u8,
    collapse_closed_shadow: []const u8,
    sidebar_bg: []const u8,
};

pub fn paletteCss(comptime p: Palette) []const u8 {
    return "    color-scheme: " ++ p.color_scheme ++ ";\n" ++
        "    --bg: " ++ p.bg ++ "; --fg: " ++ p.fg ++ "; --muted: " ++ p.muted ++ "; --accent: " ++ p.accent ++ ";\n" ++
        "    --warn: " ++ p.warn ++ ";\n" ++
        "    --code-bg: " ++ p.code_bg ++ "; --border: " ++ p.border ++ ";\n" ++
        "    --collapse-closed-bg: " ++ p.collapse_closed_bg ++ "; --collapse-open-bg: " ++ p.collapse_open_bg ++ ";\n" ++
        "    --collapse-shadow: " ++ p.collapse_shadow ++ "; --collapse-closed-shadow: " ++ p.collapse_closed_shadow ++ ";\n" ++
        "    --sidebar-bg: " ++ p.sidebar_bg ++ ";\n";
}

const fall_morning: Palette = .{
    .color_scheme = "light",
    .bg = "#faf6ef",
    .fg = "#3d2f23",
    .muted = "#8a7360",
    .accent = "#d97a2b",
    .warn = "#b0432f",
    .code_bg = "rgba(120,90,60,.12)",
    .border = "rgba(120,90,60,.28)",
    .collapse_closed_bg = "rgba(120,90,60,.06)",
    .collapse_open_bg = "var(--bg)",
    .collapse_shadow = "0 2px 10px rgba(0,0,0,.16)",
    .collapse_closed_shadow = "0 1px 4px rgba(0,0,0,.07)",
    .sidebar_bg = "#f3ead9",
};
const fall_evening: Palette = .{
    .color_scheme = "dark",
    .bg = "#16211a",
    .fg = "#e6e4d6",
    .muted = "#a3a888",
    .accent = "#a8b968",
    .warn = "#e0b568",
    .code_bg = "rgba(255,255,255,.07)",
    .border = "rgba(168,185,104,.25)",
    .collapse_closed_bg = "rgba(0,0,0,.12)",
    .collapse_open_bg = "rgba(255,255,255,.05)",
    .collapse_shadow = "none",
    .collapse_closed_shadow = "none",
    .sidebar_bg = "#101a14",
};
const winter_morning: Palette = .{
    .color_scheme = "light",
    .bg = "#ffffff",
    .fg = "#1d2a3a",
    .muted = "#5b6b7f",
    .accent = "#4a9edb",
    .warn = "#c07a1e",
    .code_bg = "rgba(90,130,170,.12)",
    .border = "rgba(90,130,170,.30)",
    .collapse_closed_bg = "rgba(90,130,170,.06)",
    .collapse_open_bg = "var(--bg)",
    .collapse_shadow = "0 2px 10px rgba(0,0,0,.16)",
    .collapse_closed_shadow = "0 1px 4px rgba(0,0,0,.07)",
    .sidebar_bg = "#f2f7fc",
};
const winter_evening: Palette = .{
    .color_scheme = "dark",
    .bg = "#0d1626",
    .fg = "#dce7f5",
    .muted = "#8fa3c0",
    .accent = "#7fb2ff",
    .warn = "#f0b45c",
    .code_bg = "rgba(255,255,255,.08)",
    .border = "rgba(220,231,245,.16)",
    .collapse_closed_bg = "rgba(0,0,0,.13)",
    .collapse_open_bg = "rgba(255,255,255,.06)",
    .collapse_shadow = "none",
    .collapse_closed_shadow = "none",
    .sidebar_bg = "#0a111e",
};
const spring_morning: Palette = .{
    .color_scheme = "light",
    .bg = "#fdf3f6",
    .fg = "#43324a",
    .muted = "#8b7392",
    .accent = "#8a6fd1",
    .warn = "#bf5f2a",
    .code_bg = "rgba(150,110,180,.12)",
    .border = "rgba(150,110,180,.26)",
    .collapse_closed_bg = "rgba(150,110,180,.06)",
    .collapse_open_bg = "var(--bg)",
    .collapse_shadow = "0 2px 10px rgba(0,0,0,.16)",
    .collapse_closed_shadow = "0 1px 4px rgba(0,0,0,.07)",
    .sidebar_bg = "#f6ecf9",
};
const spring_evening: Palette = .{
    .color_scheme = "dark",
    .bg = "#23262a",
    .fg = "#e2e6e0",
    .muted = "#9aa79b",
    .accent = "#cf6fa3",
    .warn = "#e0a35c",
    .code_bg = "rgba(255,255,255,.08)",
    .border = "rgba(207,111,163,.22)",
    .collapse_closed_bg = "rgba(0,0,0,.12)",
    .collapse_open_bg = "rgba(255,255,255,.06)",
    .collapse_shadow = "none",
    .collapse_closed_shadow = "none",
    .sidebar_bg = "#1b1e21",
};
const summer_morning: Palette = .{
    .color_scheme = "light",
    .bg = "#fbf3d9",
    .fg = "#2c3a2c",
    .muted = "#8a8560",
    .accent = "#5a9c3f",
    .warn = "#b3572d",
    .code_bg = "rgba(90,130,60,.12)",
    .border = "rgba(90,130,60,.28)",
    .collapse_closed_bg = "rgba(90,130,60,.06)",
    .collapse_open_bg = "var(--bg)",
    .collapse_shadow = "0 2px 10px rgba(0,0,0,.16)",
    .collapse_closed_shadow = "0 1px 4px rgba(0,0,0,.07)",
    .sidebar_bg = "#f5e9bd",
};
const summer_evening: Palette = .{
    .color_scheme = "dark",
    .bg = "#170c0e",
    .fg = "#ead9d9",
    .muted = "#a88b8b",
    .accent = "#c96a6a",
    .warn = "#e0a95c",
    .code_bg = "rgba(255,255,255,.07)",
    .border = "rgba(234,217,217,.14)",
    .collapse_closed_bg = "rgba(0,0,0,.14)",
    .collapse_open_bg = "rgba(255,255,255,.05)",
    .collapse_shadow = "none",
    .collapse_closed_shadow = "none",
    .sidebar_bg = "#120809",
};

// Kanagawa (after the Kanagawa.nvim colorscheme): warm ink-black background,
// crystal-blue accent, carp-yellow warn. No time variant — a single fixed
// dark palette, so morning and evening below are identical.
const kanagawa: Palette = .{
    .color_scheme = "dark",
    .bg = "#1F1F28",
    .fg = "#DCD7BA",
    .muted = "#727169",
    .accent = "#7E9CD8",
    .warn = "#E6C384",
    .code_bg = "#2A2A37",
    .border = "#54546D",
    .collapse_closed_bg = "rgba(0,0,0,.15)",
    .collapse_open_bg = "rgba(255,255,255,.05)",
    .collapse_shadow = "none",
    .collapse_closed_shadow = "none",
    .sidebar_bg = "#16161D",
};

// Vanta Black: true-black OLED palette, cyan accent. No time variant.
const vanta_black: Palette = .{
    .color_scheme = "dark",
    .bg = "#000000",
    .fg = "#E0E0E0",
    .muted = "#808080",
    .accent = "#00D9FF",
    .warn = "#FFB300",
    .code_bg = "#0A0A0A",
    .border = "#1A1A1A",
    .collapse_closed_bg = "rgba(255,255,255,.04)",
    .collapse_open_bg = "rgba(255,255,255,.08)",
    .collapse_shadow = "none",
    .collapse_closed_shadow = "none",
    .sidebar_bg = "#050505",
};

pub const Theme = struct {
    /// The `data-season` attribute value and the settings-panel button's
    /// `data-v` — the one identifier threaded through JS, CSS and markup.
    name: []const u8,
    /// The settings-panel button's visible text.
    label: []const u8,
    morning: Palette,
    evening: Palette,
};

/// Every selectable theme, in the order its button appears in the settings
/// panel. Adding a theme means adding one row here — the whitelist the
/// pre-paint bootstrap checks (`theme_season_guard`) and the button markup
/// (`theme_buttons_html`) are both generated from this table.
pub const themes = [_]Theme{
    .{ .name = "fall", .label = "Fall", .morning = fall_morning, .evening = fall_evening },
    .{ .name = "winter", .label = "Winter", .morning = winter_morning, .evening = winter_evening },
    .{ .name = "spring", .label = "Spring", .morning = spring_morning, .evening = spring_evening },
    .{ .name = "summer", .label = "Summer", .morning = summer_morning, .evening = summer_evening },
    .{ .name = "kanagawa", .label = "Kanagawa", .morning = kanagawa, .evening = kanagawa },
    .{ .name = "vanta-black", .label = "Vanta Black", .morning = vanta_black, .evening = vanta_black },
};

/// Every theme name, for anything outside this file that needs the full
/// list (e.g. validating a project's yaml `theme:` key against more than
/// the historical seasonal four — see `project.parseTheme`).
pub const theme_names = blk: {
    var names: [themes.len][]const u8 = undefined;
    for (themes, 0..) |t, i| names[i] = t.name;
    break :blk names;
};

pub const default_theme: Theme = blk: {
    for (themes) |t| {
        if (std.mem.eql(u8, t.name, "winter")) break :blk t;
    }
    unreachable;
};

// ---- tests ------------------------------------------------------------------
// The shell's generated bootstrap JS and settings-panel button markup are both
// built from the `themes` table, so these pin the invariants that generation
// relies on rather than any one palette's specific colors.

const testing = std.testing;

test "every theme name is unique and non-empty" {
    for (themes, 0..) |t, i| {
        try testing.expect(t.name.len > 0);
        for (themes[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, t.name, other.name));
    }
}

test "theme_names mirrors themes in name and order" {
    try testing.expectEqual(themes.len, theme_names.len);
    for (themes, theme_names) |t, name| try testing.expectEqualStrings(t.name, name);
}

test "default_theme is winter" {
    try testing.expectEqualStrings("winter", default_theme.name);
}

test "every palette declares light or dark, nothing else" {
    for (themes) |t| {
        for ([_]Palette{ t.morning, t.evening }) |p| {
            try testing.expect(std.mem.eql(u8, p.color_scheme, "light") or std.mem.eql(u8, p.color_scheme, "dark"));
        }
    }
}

test "paletteCss emits all 13 declarations" {
    const css = comptime paletteCss(winter_morning);
    for ([_][]const u8{
        "color-scheme:", "--bg:",                    "--fg:",
        "--muted:",      "--accent:",                 "--warn:",
        "--code-bg:",    "--border:",                 "--collapse-closed-bg:",
        "--collapse-open-bg:", "--collapse-shadow:",  "--collapse-closed-shadow:",
        "--sidebar-bg:",
    }) |decl| {
        try testing.expect(std.mem.indexOf(u8, css, decl) != null);
    }
}
