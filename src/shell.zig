//! The page chrome: the full HTML document (head, sidebar, tail) that wraps a
//! rendered markdown body fragment. Everything here is presentation — CSS, the
//! client-side JS for theme/width/sidebar persistence, and the MathJax loader
//! (the project's one runtime, client-side third-party dependency, which
//! typesets the `\( … \)` / `\[ … \]` produced by `markdown.render`). Editing
//! how a page *looks* happens here; editing markdown/`.sx` *syntax* never does.
//!
//! The only entry points are `wrapPage` (full site/project context) and
//! `standalone` (a `Shell` for `strike render`'s no-project case).

const std = @import("std");
const html = @import("html.zig");
const theme_file = @import("theme_file.zig");
const sheet = @import("sheet.zig");
const escapeInto = html.escapeInto;
const escapeAttrInto = html.escapeAttrInto;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The strike project itself. The sidebar's brand subtitle always links here —
/// it is attribution, not configuration, so no yaml key sets it.
pub const project_url = "https://github.com/jakeblackburnn/Strike";

/// One brand/breadcrumb segment: `href` is `null` for a folder with no
/// `main.*` to link to (`STRIKE_YAML.md` "main.*") — it still renders, as
/// plain text, since there's no page to send a reader to.
pub const Segment = struct { label: []const u8, href: ?[]const u8 };

/// The per-page chrome threaded into `wrapPage`: the document title, the
/// sidebar brand's breadcrumb (root first, nearest ancestor last — never the
/// current page, which the reader is already on), and the pre-rendered
/// `.sidebar-nav` contents (empty for the project picker).
pub const Shell = struct {
    title: []const u8,
    /// Root-is-always-root: `crumbs[0]` is always the site root. `site.zig`'s
    /// `breadcrumbSegments` builds this (site, then project in picker mode,
    /// then one segment per ancestor nav folder); `nav.breadcrumb: false`
    /// collapses it back to the pre-breadcrumb one-or-two-segment form.
    crumbs: []const Segment,
    nav_html: []const u8,
    /// Site default theme (season + time) and width, used as the pre-paint
    /// fallback when the reader has no `localStorage` preference yet.
    /// "" means "no default" (winter season, system-preference time).
    season: []const u8 = "",
    time: []const u8 = "",
    width: []const u8 = "",
    /// Defaults from the project's `.sxh` header. Reader preferences still
    /// win; the header's measure takes precedence over site/project width.
    typography: sheet.TypeStyle = .{},
    custom_theme: ?theme_file.ThemeFile = null,
};

/// A minimal shell for standalone rendering with no project/site context
/// (`strike render`): no sidebar nav (it degrades to nothing in `wrapPage`),
/// brand falls back to the page's own title, and there is no project root to
/// link to.
pub fn standalone(title: []const u8) Shell {
    return .{ .title = title, .crumbs = &.{.{ .label = title, .href = "#" }}, .nav_html = "" };
}

/// The `--watch` live-reload client. `server.zig` splices this before
/// `</body>` of every *served* page (never here in `wrapPage`, which the
/// static export shares — `strike build` output must stay script-free). It
/// baselines on the first successful fetch of `/__strike/gen`, then polls;
/// any change reloads the page. Fetch errors are ignored (a restarting server
/// shouldn't error-loop the page).
pub const reload_script =
    \\<script>(function(){var g=null;function p(){fetch("/__strike/gen",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){if(g===null)g=t;else if(t!==g)location.reload()}).catch(function(){})}p();setInterval(p,400);})();</script>
;

/// Wrap an already-rendered HTML `body_html` fragment in the full styled
/// document (head + body + tail), splicing in the `shell` chrome (title, brand,
/// home/repo links, sidebar nav). Used by document pages, project home pages,
/// and the picker. Caller owns/frees the returned slice.
pub fn wrapPage(allocator: Allocator, shell: Shell, body_html: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // These three land inside the pre-paint `<script>`'s string literals,
    // where attribute escaping is the wrong tool (a `\` or newline would
    // break the bootstrap and with it every stored reader preference) —
    // they're machine tokens, not prose, so validate instead of escape.
    try w.writeAll(head_pre_a);
    try w.writeAll(safeToken(shell.season));
    try w.writeAll(head_pre_b);
    try w.writeAll(safeToken(shell.time));
    try w.writeAll(head_pre_c);
    const width_default = if (shell.typography.measure) |m| safeDecimal(m[0 .. m.len - 3]) else safeToken(shell.width);
    try w.writeAll(width_default);
    try w.writeAll(head_pre_d_a);
    try w.writeAll(font_guard);
    try w.writeAll(head_pre_d_b);
    if (shell.typography.font) |font| try w.writeAll(@tagName(font));
    try w.writeAll(head_pre_d_c);
    try writeTypographyDefaults(w, shell.typography);
    if (shell.custom_theme) |theme| try writeCustomTheme(w, theme);
    try w.writeAll("<title>");
    try escapeInto(w, shell.title);
    try w.writeAll(head_post_a);
    try writeBrand(w, shell.crumbs);
    try w.writeAll(head_post_c);
    try w.writeAll(shell.nav_html);
    if (shell.custom_theme) |theme| {
        try w.writeAll(head_post_d_a);
        try w.writeAll(theme_buttons_html);
        try w.writeAll("        <button class=\"opt\" type=\"button\" data-v=\"custom\">");
        try escapeInto(w, theme.label);
        try w.writeAll("</button>\n");
        try w.writeAll(head_post_d_b);
        try w.writeAll(font_buttons_html);
        try w.writeAll(head_post_d_c);
    } else try w.writeAll(head_post_d);
    try w.writeAll(body_html);
    try w.writeAll(page_tail);
    return out.toOwnedSlice();
}

/// A value safe inside a JS string literal without escaping: ASCII
/// alphanumerics, space, `-`, `_`, at most 32 bytes. Anything else yields ""
/// — fail-soft, like the yaml the values come from.
fn safeToken(s: []const u8) []const u8 {
    if (s.len > 32) return "";
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != ' ' and c != '-' and c != '_') return "";
    }
    return s;
}

fn safeDecimal(s: []const u8) []const u8 {
    if (s.len == 0 or s.len > 12) return "";
    for (s) |c| if (!std.ascii.isDigit(c) and c != '.') return "";
    return s;
}

fn writeTypographyDefaults(w: *Writer, style: sheet.TypeStyle) Writer.Error!void {
    if (style.font == null and style.size == null and style.leading == null) return;
    try w.writeAll("<style>:root{");
    if (style.size) |v| {
        if (std.mem.endsWith(u8, v, "rem") and safeDecimal(v[0 .. v.len - 3]).len > 0) {
            try w.writeAll("--font-size:");
            try w.writeAll(v);
            try w.writeByte(';');
        }
    }
    if (style.leading) |v| {
        if (safeDecimal(v).len > 0) {
            try w.writeAll("--line-height:");
            try w.writeAll(v);
            try w.writeByte(';');
        }
    }
    try w.writeAll("}");
    if (style.font) |font| switch (font) {
        .serif => try w.writeAll(":root:not([data-font]) .content{font-family:Georgia,\"Iowan Old Style\",\"Times New Roman\",serif}"),
        .mono => try w.writeAll(":root:not([data-font]) .content{font-family:\"IBM Plex Mono\",ui-monospace,Menlo,Consolas,monospace}"),
        .sans => {},
    };
    try w.writeAll("</style>\n");
}

fn writeCustomTheme(w: *Writer, theme: theme_file.ThemeFile) Writer.Error!void {
    try w.writeAll("<style>:root[data-season=\"custom\"]:not([data-time]),:root[data-season=\"custom\"][data-time]{");
    try w.writeAll(theme.css);
    try w.writeAll("}</style>\n");
}

/// The brand is a *path*, not a name — root is always root: `crumbs[0]`
/// always reaches the site root, however deep the current page sits. Each
/// segment is its own block-level line (`.sidebar-brand`'s CSS), not joined
/// with a separator — `breadcrumbSegments` caps this at two, so the brand
/// never wraps mid-line, it just stacks: root above, the nearest thing below
/// it underneath. Every segment but the last is `.brand-site`; the last
/// (nearest ancestor) is `.brand-home`. A segment with no `href` (an
/// ancestor folder with no `main.*`) renders as plain text — there's no page
/// to send a reader to.
fn writeBrand(w: *Writer, crumbs: []const Segment) Writer.Error!void {
    for (crumbs, 0..) |seg, i| {
        const last = i == crumbs.len - 1;
        const class: []const u8 = if (last) "brand-home" else "brand-site";
        if (seg.href) |href| {
            try w.writeAll("<a class=\"");
            try w.writeAll(class);
            try w.writeAll("\" href=\"");
            try escapeAttrInto(w, href);
            try w.writeAll("\">");
            try escapeInto(w, seg.label);
            try w.writeAll("</a>");
        } else {
            try w.writeAll("<span class=\"");
            try w.writeAll(class);
            try w.writeAll("\">");
            try escapeInto(w, seg.label);
            try w.writeAll("</span>");
        }
    }
}

// The no-flash bootstrap: it restores season/time/width/font-size/line-height/
// font/sidebar before first paint. `wrapPage` splices the site default season, time, then width into the
// three `||"…"` fallbacks so an unset reader gets the site default (still
// overridable). The legacy `theme` key ("light"/"dark") migrates to a time.
const head_pre_a =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<script>(function(){try{var d=document.documentElement;var s=localStorage.getItem("season")||"
;
const head_pre_b =
    \\";var t=localStorage.getItem("time")||"
;
const head_pre_c_a =
    \\";if(!t){var l=localStorage.getItem("theme");if(l==="dark")t="evening";else if(l==="light")t="morning";}
    \\if(
;
const head_pre_c_b =
    \\)d.dataset.season=s;
    \\if(t==="morning"||t==="evening")d.dataset.time=t;var w=localStorage.getItem("width")||"
;
const head_pre_c = head_pre_c_a ++ theme_season_guard ++ "||s===\"custom\"" ++ head_pre_c_b;
const head_pre_d_a =
    \\";if(w)d.style.setProperty("--content-width",w+"rem");
    \\var fs=localStorage.getItem("fontsize");if(fs)d.style.setProperty("--font-size",fs+"px");
    \\var lh=localStorage.getItem("lineheight");if(lh)d.style.setProperty("--line-height",lh);
    \\var f=localStorage.getItem("font");if(
;
const head_pre_d_b =
    \\)d.dataset.font=f;
    \\else if(f==="")d.dataset.font="sans";
    \\else if(f===null){var hf="
;
const head_pre_d_c =
    \\";if(hf)d.dataset.font=hf;}
    \\var v=localStorage.getItem("sidebar");if(v==="collapsed")d.dataset.sidebar="collapsed";}catch(e){}})();</script>
;

const builtins = @import("themes.zig");
const Palette = builtins.Palette;
const themes = builtins.themes;
const default_theme = builtins.default_theme;
const paletteCss = builtins.paletteCss;
pub const theme_names = builtins.theme_names;

/// The pre-paint bootstrap's guard before trusting a stored `season` value:
/// `s==="fall"||s==="winter"||...` — one source, generated from `themes`,
/// covering every theme name instead of a hand-written four-way chain.
const theme_season_guard = blk: {
    var out: []const u8 = "";
    for (themes, 0..) |t, i| {
        if (i > 0) out = out ++ "||";
        out = out ++ "s===\"" ++ t.name ++ "\"";
    }
    break :blk out;
};

/// The settings-panel's theme buttons, one per row of `themes`.
const theme_buttons_html = blk: {
    var out: []const u8 = "";
    for (themes) |t| {
        out = out ++ "        <button class=\"opt\" type=\"button\" data-v=\"" ++ t.name ++ "\">" ++ t.label ++ "</button>\n";
    }
    break :blk out;
};

/// A reader-selectable body font. Adding a font means adding one row here — the CSS rule
/// (`font_rules`), the settings-panel button (`font_buttons_html`) and the
/// pre-paint bootstrap's guard (`font_guard`) are all generated from this
/// table, the same pattern `themes` establishes above.
const Font = struct {
    /// The `data-font` attribute value and the settings-panel button's
    /// `data-v`.
    name: []const u8,
    /// The settings-panel button's visible text.
    label: []const u8,
    /// A CSS `font-family` value — a full fallback stack, not a single name.
    stack: []const u8,
};

const fonts = [_]Font{
    .{ .name = "sans", .label = "Sans", .stack = "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif" },
    .{ .name = "serif", .label = "Serif", .stack = "Georgia, \"Iowan Old Style\", \"Times New Roman\", serif" },
    .{ .name = "mono", .label = "Mono", .stack = "\"IBM Plex Mono\", ui-monospace, Menlo, Consolas, \"Liberation Mono\", monospace" },
    .{ .name = "humanist", .label = "Humanist", .stack = "Seravek, \"Gill Sans Nova\", Ubuntu, Calibri, \"DejaVu Sans\", sans-serif" },
};

/// The pre-paint bootstrap's guard before trusting a stored `font` value:
/// `f==="serif"||f==="mono"||...` — generated from `fonts` so a new row does
/// not also need a hand-edited guard.
const font_guard = blk: {
    var out: []const u8 = "";
    for (fonts, 0..) |f, i| {
        if (i > 0) out = out ++ "||";
        out = out ++ "f===\"" ++ f.name ++ "\"";
    }
    break :blk out;
};

/// One `.content`-scoped font-family override per row of `fonts`.
const font_rules = blk: {
    var out: []const u8 = "";
    for (fonts) |f| {
        out = out ++ "  :root[data-font=\"" ++ f.name ++ "\"] .content { font-family: " ++ f.stack ++ "; }\n";
    }
    break :blk out;
};

/// The settings-panel's font buttons, one per row of `fonts`.
const font_buttons_html = blk: {
    var out: []const u8 = "";
    for (fonts) |f| {
        out = out ++ "        <button class=\"opt\" type=\"button\" data-v=\"" ++ f.name ++ "\">" ++ f.label ++ "</button>\n";
    }
    break :blk out;
};

fn seasonRules(comptime name: []const u8, comptime morning: Palette, comptime evening: Palette) []const u8 {
    return "  :root[data-season=\"" ++ name ++ "\"] {\n" ++ paletteCss(morning) ++ "  }\n" ++
        "  @media (prefers-color-scheme: dark) { :root[data-season=\"" ++ name ++ "\"]:not([data-time]) {\n" ++ paletteCss(evening) ++ "  } }\n" ++
        "  :root[data-season=\"" ++ name ++ "\"][data-time=\"evening\"] {\n" ++ paletteCss(evening) ++ "  }\n";
}

const theme_rules = blk: {
    var out: []const u8 =
        "  :root {\n" ++ paletteCss(default_theme.morning) ++ "  }\n" ++
        "  @media (prefers-color-scheme: dark) { :root:not([data-time]) {\n" ++ paletteCss(default_theme.evening) ++ "  } }\n" ++
        "  :root[data-time=\"evening\"] {\n" ++ paletteCss(default_theme.evening) ++ "  }\n";
    for (themes) |t| {
        out = out ++ seasonRules(t.name, t.morning, t.evening);
    }
    break :blk out;
};

// Everything from `</title>` through the opening of `<main>`. Includes the
// MathJax loader, the seasonal stylesheet (`theme_rules`), and the sidebar.
// Season/time attributes are set from `localStorage` by the head bootstrap;
// with no explicit time, the system color-scheme preference decides.
const head_post_a =
    \\</title>
    \\<script>MathJax = { tex: { inlineMath: [['\\(','\\)']], displayMath: [['\\[','\\]']] } };</script>
    \\<script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>
    \\<style>
    \\
++ theme_rules ++
    \\  :root { --sidebar-width: 14rem; }
    \\  * { box-sizing: border-box; }
    \\  body {
    \\    margin: 0; padding-left: var(--sidebar-width);
    \\    background: var(--bg); color: var(--fg);
    \\    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    \\    transition: padding-left .2s ease;
    \\  }
    \\  .content {
    \\    max-width: var(--content-width, 44rem); margin: 3rem auto; padding: 0 1.25rem;
    \\    font-size: var(--font-size, 1rem); line-height: var(--line-height, 1.6);
    \\  }
++ font_rules ++
    \\  h1, h2, h3 { line-height: 1.25; }
    \\  code {
    \\    background: var(--code-bg); padding: .15em .35em;
    \\    border-radius: 4px; font-size: .9em;
    \\    color: var(--fg); /* pinned: code never inherits color() regions (006-color) */
    \\  }
    \\  pre {
    \\    background: var(--code-bg); padding: 1rem;
    \\    border-radius: 8px; overflow-x: auto;
    \\  }
    \\  pre code { background: none; padding: 0; }
    \\  blockquote {
    \\    margin: 1rem 0; padding: .25rem 1rem;
    \\    border-left: 4px solid var(--border); color: var(--muted);
    \\  }
    \\  /* Alerts (009-alerts, restyled 2026-07-25): typed blockquotes read as
    \\     content, not asides. The type shows as a small uppercase tag, never
    \\     at body size; the bar mirrors the tag's color and never takes the
    \\     accent — informational types stay muted, urgent ones take the warn
    \\     hue, and `important` takes full-contrast body color. Only the tag
    \\     changes size and color; the quote's own content is untouched. */
    \\  blockquote.sx-alert { color: var(--fg); border-left-color: var(--muted); padding: .15rem .9rem; margin: .85rem 0; }
    \\  .sx-alert-title {
    \\    font-size: .75rem; text-transform: uppercase; letter-spacing: .08em;
    \\    font-weight: 600; color: var(--muted); margin: 0 0 .15rem;
    \\  }
    \\  .sx-alert-title + p { margin-top: 0; }
    \\  .sx-alert-warning, .sx-alert-caution, .sx-alert-todo { border-left-color: var(--warn); }
    \\  .sx-alert-warning .sx-alert-title, .sx-alert-caution .sx-alert-title, .sx-alert-todo .sx-alert-title { color: var(--warn); }
    \\  .sx-alert-important { border-left-color: var(--fg); }
    \\  .sx-alert-important .sx-alert-title { color: var(--fg); }
    \\  a { color: var(--accent); }
    \\  img { max-width: 100%; }
    \\  table { border-collapse: collapse; margin: 1rem 0; }
    \\  th, td { border: 1px solid var(--border); padding: .35rem .65rem; text-align: left; }
    \\  th { background: var(--code-bg); }
    \\  ul.sx-plain { list-style: none; padding-left: 0; }
    \\  /* Collapsible groups (007-collapse, restyled 2026-07-25): the whole
    \\     summary — the group's leader element — is the hitbox, with the
    \\     nav-folder arrow. The whole details is one card, but a quiet one:
    \\     closed it sits on a barely-there tint, a hairline bottom rule, and
    \\     a slight shadow (a trial — see the note). Open it drops the rule
    \\     (the elevation shadow carries the state on its own) and returns to
    \\     the page background. Shadows are a light-theme device; on dark
    \\     themes both tokens are `none` and the tint does the work.
    \\     `border-bottom-color: transparent` rather than removing the border,
    \\     so opening never shifts the card by a pixel.
    \\     Negative horizontal margin keeps the leader text aligned with the
    \\     body column; the summary mirrors it so its own hover highlight
    \\     (making the hitbox legible) bleeds to the same card edges. */
    \\  .sx-collapse { background: var(--collapse-closed-bg); border-radius: 8px; padding: .35rem .75rem; margin: 1rem -.75rem; border-bottom: 1px solid var(--border); box-shadow: var(--collapse-closed-shadow, none); transition: background .15s ease, box-shadow .15s ease, border-color .15s ease; }
    \\  .sx-collapse[open] { background: var(--collapse-open-bg); border-bottom-color: transparent; box-shadow: var(--collapse-shadow, none); }
    \\  .sx-collapse > summary { cursor: pointer; list-style: none; margin: -.35rem -.75rem; padding: .35rem .75rem; border-radius: 8px; transition: background .15s ease; text-indent: 0; }
    \\  .sx-collapse > summary:hover { background: rgba(125,125,125,.14); }
    \\  .sx-collapse > summary:hover::before { color: var(--accent); }
    \\  .sx-collapse > summary::-webkit-details-marker { display: none; }
    \\  .sx-collapse > summary::before { content: "\25B8"; display: inline-block; width: 1em; color: var(--muted); transition: transform .12s; }
    \\  .sx-collapse[open] > summary::before { transform: rotate(90deg); }
    \\  .sx-collapse > summary.sx-collapse-bar { display: block; min-height: 1.6em; }
    \\  /* Citations (016-citations): the cited claim is the affordance. At
    \\     rest a .sx-cite span is invisible — body text, none of the link
    \\     dress — and hover reveals it, subtly emphasizing the claim; only
    \\     the sup mark is visibly a link. `:target` tints the landing end of
    \\     a mark ↔ entry jump so the reader keeps their place both ways. The
    \\     entry list sets slightly smaller and tighter than body prose, with
    \\     the numbers in the muted margin — the bibliography look. The tints
    \\     are neutral grays so they read on every seasonal theme. */
    \\  a.sx-cite { color: inherit; text-decoration: none; border-radius: 3px; transition: background .15s ease; }
    \\  a.sx-cite:hover { background: rgba(125,125,125,.14); }
    \\  .sx-cite-mark { margin-left: .1em; }
    \\  .sx-cite-mark a { text-decoration: none; }
    \\  a.sx-cite:target, .sx-citations li:target { background: rgba(125,125,125,.14); border-radius: 3px; }
    \\  .sx-citations ol { font-size: .95em; line-height: 1.45; }
    \\  .sx-citations li { margin: .35rem 0; }
    \\  .sx-citations li::marker { color: var(--muted); }
    \\  a.sx-cite-back { color: var(--muted); text-decoration: none; }
    \\  a.sx-cite-back:hover { color: var(--accent); }
    \\  /* Captions (018-image-captions-v2): the figcaption reads smaller and
    \\     muted by default, in every position. top/bottom stack the figure as
    \\     a column and reorder visually via CSS `order` (DOM order stays
    \\     body-then-caption regardless of position). left/right split the
    \\     figure into a row — `--sx-caption-split` (an inline custom property,
    \\     the emitter's only per-instance style here) sizes the caption
    \\     column, and its own flex column with `justify-content: flex-end`
    \\     anchors short caption text to the bottom of the image's height. */
    \\  .sx-figure figcaption { font-size: .9em; color: var(--muted); }
    \\  .sx-figure-body p, .sx-figure figcaption p { margin: 0; }
    \\  .sx-figure.sx-figure-top, .sx-figure.sx-figure-bottom { display: flex; flex-direction: column; gap: .5rem; }
    \\  .sx-figure-top .sx-figure-body { order: 2; }
    \\  .sx-figure-top figcaption { order: 1; }
    \\  .sx-figure.sx-figure-left, .sx-figure.sx-figure-right { display: flex; gap: 1.5rem; }
    \\  .sx-figure-left { flex-direction: row-reverse; }
    \\  .sx-figure-right { flex-direction: row; }
    \\  .sx-figure-left .sx-figure-body, .sx-figure-right .sx-figure-body { flex: 1 1 auto; min-width: 0; }
    \\  .sx-figure-left figcaption, .sx-figure-right figcaption { flex: 0 0 var(--sx-caption-split, 30%); display: flex; flex-direction: column; justify-content: flex-end; }
    \\  /* Snug (019-snug, revised 020-snug-rework): a backward-attach group
    \\     whose only job is to remove the vertical gap between the popped
    \\     partner and its own content — no figure semantics. Targets only the
    \\     seam (first section's last child, second section's first child);
    \\     zeroing the trailing margin rather than also zeroing the leading one
    \\     keeps the result deterministic regardless of what tag each side is
    \\     (a <p> and an <h2> have different default margins). A descendant
    \\     combinator, not just a direct child, on purpose: a /cmd() single-
    \\     command chain (`/snug() /color(accent) text`) puts a plain
    \\     .sx-group wrapper div between the section and its real content, and
    \\     that div has no margin of its own to override — the actual <p>'s
    \\     default margin collapses straight through it. Matching every
    \\     first/last-child down the chain (not just the immediate one) reaches
    \\     the real content regardless of how many such wrappers sit in
    \\     between; redundantly matching the wrapper divs on the way is
    \\     harmless (same value, so collapsing keeps just the one seam). */
    \\  .sx-snug > .sx-group-sec:first-child *:last-child { margin-bottom: 0; }
    \\  .sx-snug > .sx-group-sec:last-child *:first-child { margin-top: .15rem; }
    \\  hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }
    \\  /* Spacer (021-spacer): fixed-height, no visible mark. */
    \\  .sx-spacer { height: 3rem; }
    \\  .sidebar {
    \\    position: fixed; top: 0; left: 0; width: var(--sidebar-width); height: 100vh;
    \\    display: flex; flex-direction: column; gap: 1rem;
    \\    padding: 1.25rem 1rem;
    \\    background: var(--sidebar-bg);
    \\    transition: transform .2s ease;
    \\    overflow-x: hidden;
    \\  }
    \\  /* A flex item's default min-width is `auto` — "never shrink below content's
    \\     intrinsic width" — which lets an unbreakable (nowrap) label push these
    \\     columns wider than the fixed-width sidebar, defeating the ellipsis rules
    \\     below and forcing a horizontal scrollbar. min-width: 0 lets them actually
    \\     shrink to the sidebar's width instead, so long names truncate. */
    \\  .sidebar-head, .sidebar-nav { min-width: 0; }
    \\  /* Brand block: root above, the nearest thing below it underneath —
    \\     `breadcrumbSegments` caps this at two segments, one per line, each
    \\     `display: block` so the brand always stacks instead of wrapping
    \\     mid-line; a long label truncates with an ellipsis rather than
    \\     wrapping or overflowing the sidebar. Under it a small muted subtitle
    \\     credits strike (a text link, per UI.md — the chrome's one outbound
    \\     link). */
    \\  .sidebar-head { display: flex; flex-direction: column; gap: .1rem; }
    \\  .sidebar-brand { display: flex; flex-direction: column; gap: .05rem; font-weight: 600; font-size: 1.05rem; letter-spacing: .02em; }
    \\  .brand-site, .brand-home { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    \\  .brand-home { color: inherit; text-decoration: none; }
    \\  .brand-home:hover { color: var(--accent); }
    \\  .brand-site { color: var(--muted); text-decoration: none; font-size: .85em; font-weight: 500; }
    \\  .brand-site:hover { color: var(--accent); }
    \\  .brand-repo { font-size: .75rem; color: var(--muted); text-decoration: none; }
    \\  .brand-repo:hover { color: var(--accent); text-decoration: underline; }
    \\  .sidebar-nav { flex: 1; min-height: 0; overflow-y: auto; overflow-x: hidden; }
    \\  .nav-tree { list-style: none; margin: 0; padding: 0; font-size: .88rem; }
    \\  .nav-tree .nav-tree { margin-left: .4rem; border-left: 1px solid var(--border); padding-left: .25rem; }
    \\  .nav-tree li { margin: .05rem 0; }
    \\  .nav-doc { display: block; padding: .2rem .5rem; border-radius: 6px; color: var(--muted); text-decoration: none; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    \\  .nav-doc:hover { background: var(--code-bg); color: var(--fg); }
    \\  .nav-doc.active { background: var(--accent); color: var(--on-accent); }
    \\  .nav-folder > summary { display: block; padding: .2rem .35rem; border-radius: 6px; cursor: pointer; color: var(--fg); font-weight: 600; list-style: none; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    \\  .nav-folder-link { color: inherit; text-decoration: none; }
    \\  .nav-folder-link:hover, .nav-folder-link.active { color: var(--accent); }
    \\  .nav-folder > summary::-webkit-details-marker { display: none; }
    \\  .nav-folder > summary::before { content: "\25B8"; display: inline-block; width: 1em; color: var(--muted); transition: transform .12s; }
    \\  .nav-folder[open] > summary::before { transform: rotate(90deg); }
    \\  /* The sidebar's right edge is the collapse control: a fixed strip that
    \\     draws the border line. Hovering the sidebar warms it up, hovering the
    \\     strip itself lights it accent, clicking toggles. Collapsed, the strip
    \\     slides to the screen's left edge and reopens the sidebar the same way. */
    \\  .sidebar-edge {
    \\    position: fixed; top: 0; left: calc(var(--sidebar-width) - 1.25rem); width: 2.5rem; height: 100vh; z-index: 10;
    \\    margin: 0; padding: 0; border: none; background: transparent; cursor: pointer;
    \\    transition: left .2s ease;
    \\  }
    \\  .sidebar-edge::before {
    \\    content: ""; position: absolute; top: 0; left: 50%; width: 1px; height: 100%;
    \\    background: var(--border);
    \\    transition: width .15s ease, background .15s ease, opacity .15s ease;
    \\  }
    \\  .sidebar:hover + .sidebar-edge::before { width: 2px; background: var(--accent); opacity: .35; }
    \\  .sidebar-edge:hover::before { width: 2px; background: var(--accent); opacity: .75; }
    \\  /* Collapsed: the sidebar is fully gone; only the edge strip remains. */
    \\  :root[data-sidebar="collapsed"] body { padding-left: 0; }
    \\  :root[data-sidebar="collapsed"] .sidebar {
    \\    transform: translateX(-100%); visibility: hidden;
    \\    transition: transform .2s ease, visibility 0s .2s;
    \\  }
    \\  :root[data-sidebar="collapsed"] .sidebar-edge { left: -1.25rem; }
    \\  /* Settings: two plain-text triggers; each panel pops out OVER the sidebar
    \\     (absolutely positioned above the trigger row), keeping nav uncluttered. */
    \\  .sidebar-settings { position: relative; display: flex; gap: 1rem; }
    \\  .settings-toggle {
    \\    padding: 0; font: inherit; font-size: .85rem;
    \\    color: var(--muted); background: none; border: none; cursor: pointer;
    \\  }
    \\  .settings-toggle:hover, .settings-toggle[aria-expanded="true"] { color: var(--accent); }
    \\  .settings-panel {
    \\    position: absolute; bottom: calc(100% + .5rem); left: 0; right: 0; z-index: 5;
    \\    display: flex; flex-direction: column; gap: .75rem; padding: .75rem;
    \\    background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
    \\    box-shadow: 0 2px 12px rgba(0,0,0,.15);
    \\  }
    \\  .settings-panel[hidden] { display: none; }
    \\  .opt-group { display: flex; flex-wrap: wrap; gap: .25rem .6rem; align-items: baseline; font-size: .8rem; }
    \\  .opt-label { width: 100%; color: var(--muted); }
    \\  .opt {
    \\    padding: 0; font: inherit; font-size: .85rem; background: none; border: none;
    \\    color: var(--accent); text-decoration: underline; cursor: pointer;
    \\  }
    \\  .opt.active { color: var(--fg); text-decoration: none; font-weight: 600; cursor: default; }
    \\  .control { display: flex; flex-direction: column; gap: .35rem; font-size: .8rem; color: var(--muted); }
    \\  .control-label { display: flex; justify-content: space-between; }
    \\  .width-range { width: 100%; accent-color: var(--accent); cursor: pointer; }
    \\  @media (max-width: 50rem) {
    \\    body { padding-left: 0; }
    \\    .sidebar {
    \\      position: static; width: auto; height: auto;
    \\      flex-direction: row; align-items: center; justify-content: space-between;
    \\    }
    \\    .sidebar-nav, .sidebar-settings, .sidebar-edge { display: none; }
    \\    :root[data-sidebar="collapsed"] .sidebar { display: none; }
    \\    .content { margin-top: 1.5rem; }
    \\  }
    \\</style>
    \\</head>
    \\<body>
    \\<aside class="sidebar">
    \\  <div class="sidebar-head">
    \\    <div class="sidebar-brand">
;

// `head_post_a` ends with the brand block still open, so `wrapPage` can splice
// in `writeBrand`'s one or two links and then the rendered sidebar nav.
// The brand subtitle below is a constant: it credits strike itself, so unlike
// the brand it needs nothing from the page.
const head_post_c =
    \\</div>
    \\    <a class="brand-repo" href="
++ project_url ++
    \\" target="_blank" rel="noopener noreferrer">built with strike</a>
    \\  </div>
    \\  <nav class="sidebar-nav">
;
const head_post_d_a =
    \\</nav>
    \\<script>
    \\  // Persist each sidebar folder's open/closed state under nav:<project>/<path>.
    \\  // Spliced right after the nav (not in page_tail's end-of-body script) so
    \\  // it runs before first paint: with folders open by default, running it
    \\  // late would flash every folder open, then closed, for a reader who
    \\  // collapsed one.
    \\  (function(){
    \\    var folders = document.querySelectorAll("details.nav-folder");
    \\    for (var i = 0; i < folders.length; i++) {
    \\      (function(d){
    \\        var key = "nav:" + d.dataset.folder;
    \\        try { var s = localStorage.getItem(key); if (s === "open") d.open = true; else if (s === "closed") d.open = false; } catch (e) {}
    \\        d.addEventListener("toggle", function(){ try { localStorage.setItem(key, d.open ? "open" : "closed"); } catch (e) {} });
    \\      })(folders[i]);
    \\    }
    \\  })();
    \\</script>
    \\  <div class="sidebar-settings">
    \\    <button id="theme-toggle" class="settings-toggle" type="button" aria-expanded="false">Theme</button>
    \\    <button id="text-toggle" class="settings-toggle" type="button" aria-expanded="false">Text</button>
    \\    <div id="theme-panel" class="settings-panel" hidden>
    \\      <div class="opt-group" id="season-opts">
    \\        <span class="opt-label">Theme</span>
    \\
;
const head_post_d_b =
    \\      </div>
    \\      <div class="opt-group" id="time-opts">
    \\        <span class="opt-label">Time</span>
    \\        <button class="opt" type="button" data-v="">Auto</button>
    \\        <button class="opt" type="button" data-v="morning">Morning</button>
    \\        <button class="opt" type="button" data-v="evening">Evening</button>
    \\      </div>
    \\    </div>
    \\    <div id="text-panel" class="settings-panel" hidden>
    \\      <label class="control" for="width-range">
    \\        <span class="control-label"><span>Width</span><span id="width-value">44rem</span></span>
    \\        <input id="width-range" class="width-range" type="range" min="30" max="72" step="1" value="44">
    \\      </label>
    \\      <label class="control" for="size-range">
    \\        <span class="control-label"><span>Size</span><span id="size-value">16px</span></span>
    \\        <input id="size-range" class="width-range" type="range" min="13" max="22" step="1" value="16">
    \\      </label>
    \\      <label class="control" for="line-range">
    \\        <span class="control-label"><span>Line height</span><span id="line-value">1.6</span></span>
    \\        <input id="line-range" class="width-range" type="range" min="1.2" max="2" step="0.05" value="1.6">
    \\      </label>
    \\      <div class="opt-group" id="font-opts">
    \\        <span class="opt-label">Font</span>
;
const head_post_d_c =
    \\      </div>
    \\    </div>
    \\  </div>
    \\</aside>
    \\<button id="sidebar-edge" class="sidebar-edge" type="button" aria-label="Toggle sidebar" title="Toggle sidebar"></button>
    \\<main class="content">
    \\
;
const head_post_d = head_post_d_a ++ theme_buttons_html ++ head_post_d_b ++ font_buttons_html ++ head_post_d_c;

const page_tail =
    \\</main>
    \\<script>
    \\(function(){
    \\  var d = document.documentElement;
    \\  var edge = document.getElementById("sidebar-edge");
    \\  if (edge) {
    \\    function edgeLabel(){
    \\      var l = d.dataset.sidebar === "collapsed" ? "Show sidebar" : "Hide sidebar";
    \\      edge.setAttribute("aria-label", l); edge.title = l;
    \\    }
    \\    edgeLabel();
    \\    edge.addEventListener("click", function(){
    \\      var collapsed = d.dataset.sidebar === "collapsed";
    \\      if (collapsed) delete d.dataset.sidebar; else d.dataset.sidebar = "collapsed";
    \\      try { localStorage.setItem("sidebar", collapsed ? "expanded" : "collapsed"); } catch (e) {}
    \\      edgeLabel();
    \\    });
    \\  }
    \\
    \\  // Two settings pop-outs (theme, text); opening one closes the other.
    \\  var panels = [
    \\    [document.getElementById("theme-toggle"), document.getElementById("theme-panel")],
    \\    [document.getElementById("text-toggle"), document.getElementById("text-panel")]
    \\  ];
    \\  panels.forEach(function(pair){
    \\    if (!pair[0] || !pair[1]) return;
    \\    pair[0].addEventListener("click", function(){
    \\      var show = pair[1].hidden;
    \\      panels.forEach(function(q){
    \\        if (!q[0] || !q[1]) return;
    \\        q[1].hidden = true;
    \\        q[0].setAttribute("aria-expanded", "false");
    \\      });
    \\      pair[1].hidden = !show;
    \\      pair[0].setAttribute("aria-expanded", show ? "true" : "false");
    \\    });
    \\  });
    \\
    \\  // Theme options are plain text links; the current choice is marked active.
    \\  function optGroup(id, current, apply){
    \\    var wrap = document.getElementById(id);
    \\    if (!wrap) return;
    \\    var opts = wrap.querySelectorAll(".opt");
    \\    function mark(v){
    \\      for (var i = 0; i < opts.length; i++)
    \\        opts[i].classList.toggle("active", opts[i].dataset.v === v);
    \\    }
    \\    mark(current);
    \\    for (var i = 0; i < opts.length; i++)
    \\      (function(o){
    \\        o.addEventListener("click", function(){ apply(o.dataset.v); mark(o.dataset.v); });
    \\      })(opts[i]);
    \\  }
    \\  optGroup("season-opts", d.dataset.season || "winter", function(v){
    \\    d.dataset.season = v;
    \\    try { localStorage.setItem("season", v); } catch (e) {}
    \\  });
    \\  optGroup("time-opts", d.dataset.time || "", function(v){
    \\    if (v) d.dataset.time = v; else delete d.dataset.time;
    \\    try {
    \\      if (v) localStorage.setItem("time", v); else localStorage.removeItem("time");
    \\      localStorage.removeItem("theme");
    \\    } catch (e) {}
    \\  });
    \\  optGroup("font-opts", d.dataset.font || "", function(v){
    \\    if (v) d.dataset.font = v; else delete d.dataset.font;
    \\    try { if (v) localStorage.setItem("font", v); else localStorage.removeItem("font"); } catch (e) {}
    \\  });
    \\
    \\  // Text sliders share one shape: restore from localStorage, apply live,
    \\  // echo the value next to the label. With nothing saved the slider must
    \\  // apply nothing — the head bootstrap has already put a default in
    \\  // effect (yaml `width:` inline on the root, or an `.sxh` header's
    \\  // size/leading via a <style> rule), and applying here would overwrite
    \\  // it with the markup's own default. So an unset reader only syncs the
    \\  // knob to whatever is already in effect — read via computed style,
    \\  // since a stylesheet rule never shows up on the inline style object.
    \\  function slider(id, valId, key, unit, prop, apply){
    \\    var range = document.getElementById(id);
    \\    var val = document.getElementById(valId);
    \\    if (!range) return;
    \\    var saved = null;
    \\    try { saved = localStorage.getItem(key); } catch (e) {}
    \\    if (saved) { range.value = saved; apply(saved); }
    \\    else {
    \\      var cur = parseFloat(getComputedStyle(d).getPropertyValue(prop));
    \\      if (!isNaN(cur)) range.value = cur;
    \\    }
    \\    if (val) val.textContent = range.value + unit;
    \\    range.addEventListener("input", function(){
    \\      apply(range.value);
    \\      if (val) val.textContent = range.value + unit;
    \\      try { localStorage.setItem(key, range.value); } catch (e) {}
    \\    });
    \\  }
    \\  slider("width-range", "width-value", "width", "rem", "--content-width", function(v){
    \\    d.style.setProperty("--content-width", v + "rem");
    \\  });
    \\  slider("size-range", "size-value", "fontsize", "px", "--font-size", function(v){
    \\    d.style.setProperty("--font-size", v + "px");
    \\  });
    \\  slider("line-range", "line-value", "lineheight", "", "--line-height", function(v){
    \\    d.style.setProperty("--line-height", v);
    \\  });
    \\
    \\  var navActive = document.querySelector(".sidebar-nav .nav-doc.active");
    \\  if (navActive) navActive.scrollIntoView({ block: "center" });
    \\})();
    \\</script>
    \\</body>
    \\</html>
    \\
;

// ---- tests ------------------------------------------------------------------

test "wrapPage emits sidebar, settings panel and content body" {
    const shell: Shell = .{
        .title = "Doc",
        .crumbs = &.{.{ .label = "Data Mining", .href = "/" }},
        .nav_html = "<ul class=\"nav-tree\"></ul>",
    };
    const page = try wrapPage(std.testing.allocator, shell, "<p>hi</p>\n");
    defer std.testing.allocator.free(page);

    // Title is present between the title tags.
    try std.testing.expect(std.mem.indexOf(u8, page, "<title>Doc</title>") != null);
    // Brand text, its home link, and the spliced nav all land in the shell.
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"brand-home\" href=\"/\">Data Mining</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<nav class=\"sidebar-nav\"><ul class=\"nav-tree\"></ul></nav>") != null);
    // The fragment body is wrapped in the content region.
    try std.testing.expect(std.mem.indexOf(u8, page, "<main class=\"content\">\n<p>hi</p>\n") != null);
    // Separate theme and text pop-outs; theme options are text-link buttons.
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"theme-toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"text-toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"theme-panel\" class=\"settings-panel\" hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"text-panel\" class=\"settings-panel\" hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"opt\" type=\"button\" data-v=\"spring\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"opt\" type=\"button\" data-v=\"evening\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"width-range\"") != null);
    // Text panel: font size and line-height sliders plus the font opt group.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"size-range\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"line-range\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"opt\" type=\"button\" data-v=\"serif\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"fontsize\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"lineheight\")") != null);
    // The sidebar's right edge is the collapse toggle; collapsing slides the
    // sidebar away and leaves the strip at the screen edge.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"sidebar-edge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"sidebar-toggle\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"sidebar-open\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".sidebar:hover + .sidebar-edge::before") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-sidebar=\"collapsed\"] .sidebar-edge { left: -1.25rem; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"sidebar\")") != null);
    // The brand subtitle credits strike and opens in a new tab.
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"brand-repo\" href=\"" ++ project_url ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ">built with strike</a>") != null);
    // Content width is driven by the CSS variable the slider sets.
    try std.testing.expect(std.mem.indexOf(u8, page, "max-width: var(--content-width, 44rem)") != null);
    // The seasonal rules and the no-flash bootstrap are wired up.
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-season=\"fall\"][data-time=\"evening\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-season=\"summer\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"season\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"time\")") != null);
}

test "collapse summary resets text-indent so an ancestor indent() never reaches the arrow" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    // A `// indent()` group wrapping a `// collapse()` group inherits
    // text-indent onto <details>/<summary> via plain CSS inheritance (the
    // groups nest, so there is no shared Attrs to guard in the emitter);
    // the summary rule must reset it back to 0 so the disclosure arrow
    // never shifts into the leader text.
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-collapse > summary { cursor: pointer; list-style: none; margin: -.35rem -.75rem; padding: .35rem .75rem; border-radius: 8px; transition: background .15s ease; text-indent: 0; }") != null);
}

test "caption CSS: default figcaption style, position flex/order rules, and the split-percent var" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-figure figcaption { font-size: .9em; color: var(--muted); }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-figure-top .sx-figure-body { order: 2; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-figure-left { flex-direction: row-reverse; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "flex: 0 0 var(--sx-caption-split, 30%)") != null);
}

test "figure/caption spacing: inner paragraph margins reset, deliberate flex gap replaces them" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    // Without this, the image's and figcaption's own <p> margins don't
    // collapse across the flex-item boundary — they sum to ~2em instead.
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-figure-body p, .sx-figure figcaption p { margin: 0; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-figure.sx-figure-top, .sx-figure.sx-figure-bottom { display: flex; flex-direction: column; gap: .5rem; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-figure.sx-figure-left, .sx-figure.sx-figure-right { display: flex; gap: 1.5rem; }") != null);
}

test "alert CSS: title's tight bottom margin isn't lost to the following paragraph's default margin" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-alert-title + p { margin-top: 0; }") != null);
}

test "snug CSS: seam between the popped partner and the attached content is tightened" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-snug > .sx-group-sec:first-child *:last-child { margin-bottom: 0; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-snug > .sx-group-sec:last-child *:first-child { margin-top: .15rem; }") != null);
}

test "snug CSS: descendant combinator, not just direct child, reaches through a /cmd() chain's wrapper div" {
    // `/snug() /color(accent) text` puts a plain .sx-group wrapper div
    // between the section and its real content (020-snug-rework.md) — a
    // `>` (direct-child) selector would only reach that wrapper, which has
    // no margin of its own, and the real element's default margin would
    // collapse straight through it, undoing the tightened seam. `*` (any
    // descendant) reaches every first/last-child down the chain instead.
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "> .sx-group-sec:first-child > :last-child") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "> .sx-group-sec:last-child > :first-child") == null);
}

test "kanagawa and vanta-black themes: selectable and carry their own palette" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    // Buttons: generated from the same table as the seasonal four.
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"opt\" type=\"button\" data-v=\"kanagawa\">Kanagawa</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"opt\" type=\"button\" data-v=\"vanta-black\">Vanta Black</button>") != null);
    // Pre-paint bootstrap accepts both as valid `data-season` values.
    try std.testing.expect(std.mem.indexOf(u8, page, "s===\"kanagawa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "s===\"vanta-black\"") != null);
    // Each has its own CSS rule carrying its own accent color.
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-season=\"kanagawa\"] {\n    color-scheme: dark;\n    --bg: #1F1F28; --fg: #DCD7BA; --muted: #727169; --accent: #7E9CD8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-season=\"vanta-black\"] {\n    color-scheme: dark;\n    --bg: #000000; --fg: #E0E0E0; --muted: #808080; --accent: #EDEAE0;\n    --on-accent: #0A0A0A;") != null);
}

test "existing seasonal theme CSS is byte-identical after the data-driven refactor" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page,
        \\  :root[data-season="winter"] {
        \\    color-scheme: light;
        \\    --bg: #ffffff; --fg: #1d2a3a; --muted: #5b6b7f; --accent: #4a9edb;
        \\    --on-accent: #fff;
        \\    --warn: #c07a1e;
        \\    --code-bg: rgba(90,130,170,.12); --border: rgba(90,130,170,.30);
        \\    --collapse-closed-bg: rgba(90,130,170,.06); --collapse-open-bg: var(--bg);
        \\    --collapse-shadow: 0 2px 10px rgba(0,0,0,.16); --collapse-closed-shadow: 0 1px 4px rgba(0,0,0,.07);
        \\    --sidebar-bg: #f2f7fc;
        \\  }
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\  :root[data-season="fall"][data-time="evening"] {
        \\    color-scheme: dark;
        \\    --bg: #16211a; --fg: #e6e4d6; --muted: #a3a888; --accent: #a8b968;
        \\    --on-accent: #fff;
        \\    --warn: #e0b568;
        \\    --code-bg: rgba(255,255,255,.07); --border: rgba(168,185,104,.25);
        \\    --collapse-closed-bg: rgba(0,0,0,.12); --collapse-open-bg: rgba(255,255,255,.05);
        \\    --collapse-shadow: none; --collapse-closed-shadow: none;
        \\    --sidebar-bg: #101a14;
        \\  }
    ) != null);
}

test "spacer CSS: fixed height" {
    const shell: Shell = .{ .title = "T", .crumbs = &.{.{ .label = "B", .href = "/" }}, .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-spacer { height: 3rem; }") != null);
}

test "standalone shell has no nav and no project root to link to" {
    const shell = standalone("My Doc");
    const page = try wrapPage(std.testing.allocator, shell, "<p>hi</p>\n");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "<title>My Doc</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "brand-home\" href=\"#\">My Doc</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<nav class=\"sidebar-nav\"></nav>") != null);
    // The subtitle is attribution, so even a standalone page carries it.
    try std.testing.expect(std.mem.indexOf(u8, page, ">built with strike</a>") != null);
}

test "writeBrand: each segment is its own block-level line, no separator; an unlinked segment renders as plain text" {
    const shell: Shell = .{
        .title = "T",
        .crumbs = &.{
            .{ .label = "Site", .href = "/" },
            .{ .label = "Design", .href = null }, // no main.* — nothing to link to
        },
        .nav_html = "",
    };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    // No `brand-sep` glyph between them — CSS (`display: block` on both
    // classes) stacks them into separate lines instead.
    try std.testing.expect(std.mem.indexOf(u8, page,
        "<a class=\"brand-site\" href=\"/\">Site</a><span class=\"brand-home\">Design</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "brand-sep") == null);
}

test "wrapPage wires the pre-paint theme bootstrap and never the reload script" {
    const sh: Shell = .{
        .title = "T",
        .crumbs = &.{.{ .label = "B", .href = "/" }},
        .nav_html = "",
    };
    const page = try wrapPage(std.testing.allocator, sh, "<p>x</p>\n");
    defer std.testing.allocator.free(page);
    // The head bootstrap restores season/time before first paint.
    try std.testing.expect(std.mem.indexOf(u8, page, "data-season") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-time") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage") != null);
    // The live-reload script is spliced in server.zig only — a wrapped page
    // (what static export emits) must never contain it.
    try std.testing.expect(std.mem.indexOf(u8, page, reload_script) == null);
}

test "header typography sets defaults beneath saved reader preferences" {
    const sh: Shell = .{
        .title = "T",
        .crumbs = &.{.{ .label = "B", .href = "/" }},
        .nav_html = "",
        .width = "46",
        .typography = .{ .font = .serif, .measure = "34rem", .size = "1rem", .leading = "1.5" },
    };
    const page = try wrapPage(std.testing.allocator, sh, "<p>x</p>\n");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"width\")||\"34\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "--font-size:1rem;--line-height:1.5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":root:not([data-font]) .content{font-family:Georgia") != null);
}

test "project theme file is inlined and selectable" {
    const sh: Shell = .{
        .title = "T",
        .crumbs = &.{.{ .label = "B", .href = "/" }},
        .nav_html = "",
        .season = "custom",
        .custom_theme = .{ .label = "Paper & Ink", .css = "color-scheme:dark;--bg:#101010;" },
    };
    const page = try wrapPage(std.testing.allocator, sh, "<p>x</p>\n");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "s===\"custom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-v=\"custom\">Paper &amp; Ink</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-season=\"custom\"]:not([data-time])") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "--bg:#101010;") != null);
}
