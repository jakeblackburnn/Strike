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
const escapeInto = html.escapeInto;
const escapeAttrInto = html.escapeAttrInto;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The strike project itself. The sidebar's brand subtitle always links here —
/// it is attribution, not configuration, so no yaml key sets it.
pub const project_url = "https://github.com/jakeblackburnn/Strike";

/// The per-page chrome threaded into `wrapPage`: the document title, the sidebar
/// brand text and the link it carries (the current project's own root), and the
/// pre-rendered `.sidebar-nav` contents (empty for the project picker).
pub const Shell = struct {
    title: []const u8,
    brand: []const u8,
    /// Where the brand links: the root of the project being read (`/<slug>`,
    /// or `/` for a root project and the picker).
    home_href: []const u8,
    nav_html: []const u8,
    /// Site default theme (season + time) and width, used as the pre-paint
    /// fallback when the reader has no `localStorage` preference yet.
    /// "" means "no default" (winter season, system-preference time).
    season: []const u8 = "",
    time: []const u8 = "",
    width: []const u8 = "",
};

/// A minimal shell for standalone rendering with no project/site context
/// (`strike render`): no sidebar nav (it degrades to nothing in `wrapPage`),
/// brand falls back to the page's own title, and there is no project root to
/// link to.
pub fn standalone(title: []const u8) Shell {
    return .{ .title = title, .brand = title, .home_href = "#", .nav_html = "" };
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
    try w.writeAll(head_pre_a);
    try escapeAttrInto(w, shell.season);
    try w.writeAll(head_pre_b);
    try escapeAttrInto(w, shell.time);
    try w.writeAll(head_pre_c);
    try escapeAttrInto(w, shell.width);
    try w.writeAll(head_pre_d);
    try escapeInto(w, shell.title);
    try w.writeAll(head_post_a);
    try escapeAttrInto(w, shell.home_href);
    try w.writeAll(head_post_b);
    try escapeInto(w, shell.brand);
    try w.writeAll(head_post_c);
    try w.writeAll(shell.nav_html);
    try w.writeAll(head_post_d);
    try w.writeAll(body_html);
    try w.writeAll(page_tail);
    return out.toOwnedSlice();
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
const head_pre_c =
    \\";if(!t){var l=localStorage.getItem("theme");if(l==="dark")t="evening";else if(l==="light")t="morning";}
    \\if(s==="fall"||s==="winter"||s==="spring"||s==="summer")d.dataset.season=s;
    \\if(t==="morning"||t==="evening")d.dataset.time=t;var w=localStorage.getItem("width")||"
;
const head_pre_d =
    \\";if(w)d.style.setProperty("--content-width",w+"rem");
    \\var fs=localStorage.getItem("fontsize");if(fs)d.style.setProperty("--font-size",fs+"px");
    \\var lh=localStorage.getItem("lineheight");if(lh)d.style.setProperty("--line-height",lh);
    \\var f=localStorage.getItem("font");if(f==="serif")d.dataset.font=f;
    \\var v=localStorage.getItem("sidebar");if(v==="collapsed")d.dataset.sidebar="collapsed";}catch(e){}})();</script>
    \\<title>
;

// The seasonal palettes: four themes, each a "morning" (light) and "evening"
// (dark) token set. `seasonRules` splices each pair into three rules — the
// season's base (morning), its system-dark fallback when no explicit time is
// chosen, and its explicit-evening override. Winter is the default season, so
// its tokens also fill the bare `:root` rules (pages with no attributes set —
// JS disabled, static export before the bootstrap runs).
const fall_morning =
    \\    color-scheme: light;
    \\    --bg: #faf6ef; --fg: #3d2f23; --muted: #8a7360; --accent: #d97a2b;
    \\    --warn: #b0432f;
    \\    --code-bg: rgba(120,90,60,.12); --border: rgba(120,90,60,.28);
    \\    --collapse-closed-bg: rgba(120,90,60,.06); --collapse-open-bg: var(--bg);
    \\    --collapse-shadow: 0 2px 10px rgba(0,0,0,.16);
    \\    --collapse-closed-shadow: 0 1px 4px rgba(0,0,0,.07);
    \\    --sidebar-bg: #f3ead9;
;
const fall_evening =
    \\    color-scheme: dark;
    \\    --bg: #16211a; --fg: #e6e4d6; --muted: #a3a888; --accent: #a8b968;
    \\    --warn: #e0b568;
    \\    --code-bg: rgba(255,255,255,.07); --border: rgba(168,185,104,.25);
    \\    --collapse-closed-bg: rgba(0,0,0,.12); --collapse-open-bg: rgba(255,255,255,.05);
    \\    --collapse-shadow: none; --collapse-closed-shadow: none;
    \\    --sidebar-bg: #101a14;
;
const winter_morning =
    \\    color-scheme: light;
    \\    --bg: #ffffff; --fg: #1d2a3a; --muted: #5b6b7f; --accent: #4a9edb;
    \\    --warn: #c07a1e;
    \\    --code-bg: rgba(90,130,170,.12); --border: rgba(90,130,170,.30);
    \\    --collapse-closed-bg: rgba(90,130,170,.06); --collapse-open-bg: var(--bg);
    \\    --collapse-shadow: 0 2px 10px rgba(0,0,0,.16);
    \\    --collapse-closed-shadow: 0 1px 4px rgba(0,0,0,.07);
    \\    --sidebar-bg: #f2f7fc;
;
const winter_evening =
    \\    color-scheme: dark;
    \\    --bg: #0d1626; --fg: #dce7f5; --muted: #8fa3c0; --accent: #7fb2ff;
    \\    --warn: #f0b45c;
    \\    --code-bg: rgba(255,255,255,.08); --border: rgba(220,231,245,.16);
    \\    --collapse-closed-bg: rgba(0,0,0,.13); --collapse-open-bg: rgba(255,255,255,.06);
    \\    --collapse-shadow: none; --collapse-closed-shadow: none;
    \\    --sidebar-bg: #0a111e;
;
const spring_morning =
    \\    color-scheme: light;
    \\    --bg: #fdf3f6; --fg: #43324a; --muted: #8b7392; --accent: #8a6fd1;
    \\    --warn: #bf5f2a;
    \\    --code-bg: rgba(150,110,180,.12); --border: rgba(150,110,180,.26);
    \\    --collapse-closed-bg: rgba(150,110,180,.06); --collapse-open-bg: var(--bg);
    \\    --collapse-shadow: 0 2px 10px rgba(0,0,0,.16);
    \\    --collapse-closed-shadow: 0 1px 4px rgba(0,0,0,.07);
    \\    --sidebar-bg: #f6ecf9;
;
const spring_evening =
    \\    color-scheme: dark;
    \\    --bg: #23262a; --fg: #e2e6e0; --muted: #9aa79b; --accent: #cf6fa3;
    \\    --warn: #e0a35c;
    \\    --code-bg: rgba(255,255,255,.08); --border: rgba(207,111,163,.22);
    \\    --collapse-closed-bg: rgba(0,0,0,.12); --collapse-open-bg: rgba(255,255,255,.06);
    \\    --collapse-shadow: none; --collapse-closed-shadow: none;
    \\    --sidebar-bg: #1b1e21;
;
const summer_morning =
    \\    color-scheme: light;
    \\    --bg: #fbf3d9; --fg: #2c3a2c; --muted: #8a8560; --accent: #5a9c3f;
    \\    --warn: #b3572d;
    \\    --code-bg: rgba(90,130,60,.12); --border: rgba(90,130,60,.28);
    \\    --collapse-closed-bg: rgba(90,130,60,.06); --collapse-open-bg: var(--bg);
    \\    --collapse-shadow: 0 2px 10px rgba(0,0,0,.16);
    \\    --collapse-closed-shadow: 0 1px 4px rgba(0,0,0,.07);
    \\    --sidebar-bg: #f5e9bd;
;
const summer_evening =
    \\    color-scheme: dark;
    \\    --bg: #170c0e; --fg: #ead9d9; --muted: #a88b8b; --accent: #c96a6a;
    \\    --warn: #e0a95c;
    \\    --code-bg: rgba(255,255,255,.07); --border: rgba(234,217,217,.14);
    \\    --collapse-closed-bg: rgba(0,0,0,.14); --collapse-open-bg: rgba(255,255,255,.05);
    \\    --collapse-shadow: none; --collapse-closed-shadow: none;
    \\    --sidebar-bg: #120809;
;

fn seasonRules(comptime name: []const u8, comptime morning: []const u8, comptime evening: []const u8) []const u8 {
    return "  :root[data-season=\"" ++ name ++ "\"] {\n" ++ morning ++ "\n  }\n" ++
        "  @media (prefers-color-scheme: dark) { :root[data-season=\"" ++ name ++ "\"]:not([data-time]) {\n" ++ evening ++ "\n  } }\n" ++
        "  :root[data-season=\"" ++ name ++ "\"][data-time=\"evening\"] {\n" ++ evening ++ "\n  }\n";
}

const theme_rules =
    "  :root {\n" ++ winter_morning ++ "\n  }\n" ++
    "  @media (prefers-color-scheme: dark) { :root:not([data-time]) {\n" ++ winter_evening ++ "\n  } }\n" ++
    "  :root[data-time=\"evening\"] {\n" ++ winter_evening ++ "\n  }\n" ++
    seasonRules("fall", fall_morning, fall_evening) ++
    seasonRules("winter", winter_morning, winter_evening) ++
    seasonRules("spring", spring_morning, spring_evening) ++
    seasonRules("summer", summer_morning, summer_evening);

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
    \\  * { box-sizing: border-box; }
    \\  body {
    \\    margin: 0; padding-left: 14rem;
    \\    background: var(--bg); color: var(--fg);
    \\    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    \\    transition: padding-left .2s ease;
    \\  }
    \\  .content {
    \\    max-width: var(--content-width, 44rem); margin: 3rem auto; padding: 0 1.25rem;
    \\    font-size: var(--font-size, 1rem); line-height: var(--line-height, 1.6);
    \\  }
    \\  :root[data-font="serif"] .content { font-family: Georgia, "Iowan Old Style", "Times New Roman", serif; }
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
    \\  .sx-alert-warning, .sx-alert-caution, .sx-alert-todo { border-left-color: var(--warn); }
    \\  .sx-alert-warning .sx-alert-title, .sx-alert-caution .sx-alert-title, .sx-alert-todo .sx-alert-title { color: var(--warn); }
    \\  .sx-alert-important { border-left-color: var(--fg); }
    \\  .sx-alert-important .sx-alert-title { color: var(--fg); }
    \\  a { color: var(--accent); }
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
    \\  .sx-collapse > summary:hover { background: rgba(0,0,0,.07); }
    \\  .sx-collapse > summary:hover::before { color: var(--accent); }
    \\  .sx-collapse > summary::-webkit-details-marker { display: none; }
    \\  .sx-collapse > summary::before { content: "\25B8"; display: inline-block; width: 1em; color: var(--muted); transition: transform .12s; }
    \\  .sx-collapse[open] > summary::before { transform: rotate(90deg); }
    \\  .sx-collapse > summary > * { display: inline; }
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
    \\  hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }
    \\  .sidebar {
    \\    position: fixed; top: 0; left: 0; width: 14rem; height: 100vh;
    \\    display: flex; flex-direction: column; gap: 1rem;
    \\    padding: 1.25rem 1rem;
    \\    background: var(--sidebar-bg);
    \\    transition: transform .2s ease;
    \\  }
    \\  /* Brand block: the project title links to that project's own root, with
    \\     a small muted subtitle crediting strike (a text link, per UI.md — the
    \\     one outbound link in the chrome). */
    \\  .sidebar-head { display: flex; flex-direction: column; gap: .1rem; }
    \\  .sidebar-brand { font-weight: 600; font-size: 1.05rem; letter-spacing: .02em; }
    \\  .brand-home { color: inherit; text-decoration: none; }
    \\  .brand-home:hover { color: var(--accent); }
    \\  .brand-repo { font-size: .75rem; color: var(--muted); text-decoration: none; }
    \\  .brand-repo:hover { color: var(--accent); text-decoration: underline; }
    \\  .sidebar-nav { flex: 1; min-height: 0; overflow-y: auto; }
    \\  .nav-tree { list-style: none; margin: 0; padding: 0; font-size: .88rem; }
    \\  .nav-tree .nav-tree { margin-left: .4rem; border-left: 1px solid var(--border); padding-left: .25rem; }
    \\  .nav-tree li { margin: .05rem 0; }
    \\  .nav-doc { display: block; padding: .2rem .5rem; border-radius: 6px; color: var(--muted); text-decoration: none; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    \\  .nav-doc:hover { background: var(--code-bg); color: var(--fg); }
    \\  .nav-doc.active { background: var(--accent); color: #fff; }
    \\  .nav-folder > summary { padding: .2rem .35rem; border-radius: 6px; cursor: pointer; color: var(--fg); font-weight: 600; list-style: none; white-space: nowrap; }
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
    \\    position: fixed; top: 0; left: calc(14rem - .75rem); width: 1.5rem; height: 100vh; z-index: 10;
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
    \\  :root[data-sidebar="collapsed"] .sidebar-edge { left: -.75rem; }
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
    \\    <div class="sidebar-brand"><a class="brand-home" href="
;

// `head_post_a` ends mid-attribute so `wrapPage` can splice the brand's link
// (the current project's root), the brand text, and the rendered sidebar nav.
const head_post_b =
    \\">
;

// The brand subtitle is a constant: it credits strike itself, so unlike the
// brand above it needs nothing from the page.
const head_post_c =
    \\</a></div>
    \\    <a class="brand-repo" href="
++ project_url ++
    \\" target="_blank" rel="noopener noreferrer">built with strike</a>
    \\  </div>
    \\  <nav class="sidebar-nav">
;
const head_post_d =
    \\</nav>
    \\  <div class="sidebar-settings">
    \\    <button id="theme-toggle" class="settings-toggle" type="button" aria-expanded="false">Theme</button>
    \\    <button id="text-toggle" class="settings-toggle" type="button" aria-expanded="false">Text</button>
    \\    <div id="theme-panel" class="settings-panel" hidden>
    \\      <div class="opt-group" id="season-opts">
    \\        <span class="opt-label">Season</span>
    \\        <button class="opt" type="button" data-v="fall">Fall</button>
    \\        <button class="opt" type="button" data-v="winter">Winter</button>
    \\        <button class="opt" type="button" data-v="spring">Spring</button>
    \\        <button class="opt" type="button" data-v="summer">Summer</button>
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
    \\        <button class="opt" type="button" data-v="">Sans</button>
    \\        <button class="opt" type="button" data-v="serif">Serif</button>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</aside>
    \\<button id="sidebar-edge" class="sidebar-edge" type="button" aria-label="Toggle sidebar" title="Toggle sidebar"></button>
    \\<main class="content">
    \\
;

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
    \\  // echo the value next to the label.
    \\  function slider(id, valId, key, unit, apply){
    \\    var range = document.getElementById(id);
    \\    var val = document.getElementById(valId);
    \\    if (!range) return;
    \\    var saved = null;
    \\    try { saved = localStorage.getItem(key); } catch (e) {}
    \\    if (saved) range.value = saved;
    \\    function go(v){ apply(v); if (val) val.textContent = v + unit; }
    \\    go(range.value);
    \\    range.addEventListener("input", function(){
    \\      go(range.value);
    \\      try { localStorage.setItem(key, range.value); } catch (e) {}
    \\    });
    \\  }
    \\  slider("width-range", "width-value", "width", "rem", function(v){
    \\    d.style.setProperty("--content-width", v + "rem");
    \\  });
    \\  slider("size-range", "size-value", "fontsize", "px", function(v){
    \\    d.style.setProperty("--font-size", v + "px");
    \\  });
    \\  slider("line-range", "line-value", "lineheight", "", function(v){
    \\    d.style.setProperty("--line-height", v);
    \\  });
    \\
    \\  // Persist each sidebar folder's open/closed state under nav:<project>/<path>.
    \\  var folders = document.querySelectorAll("details.nav-folder");
    \\  for (var i = 0; i < folders.length; i++) {
    \\    (function(d){
    \\      var key = "nav:" + d.dataset.folder;
    \\      try { var s = localStorage.getItem(key); if (s === "open") d.open = true; else if (s === "closed") d.open = false; } catch (e) {}
    \\      d.addEventListener("toggle", function(){ try { localStorage.setItem(key, d.open ? "open" : "closed"); } catch (e) {} });
    \\    })(folders[i]);
    \\  }
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
        .brand = "Data Mining",
        .home_href = "/",
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
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-sidebar=\"collapsed\"] .sidebar-edge { left: -.75rem; }") != null);
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
    const shell: Shell = .{ .title = "T", .brand = "B", .home_href = "/", .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    // A `// indent()` group wrapping a `// collapse()` group inherits
    // text-indent onto <details>/<summary> via plain CSS inheritance (the
    // groups nest, so there is no shared Attrs to guard in the emitter);
    // the summary rule must reset it back to 0 so the disclosure arrow
    // never shifts into the leader text.
    try std.testing.expect(std.mem.indexOf(u8, page, ".sx-collapse > summary { cursor: pointer; list-style: none; margin: -.35rem -.75rem; padding: .35rem .75rem; border-radius: 8px; transition: background .15s ease; text-indent: 0; }") != null);
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

test "wrapPage wires the pre-paint theme bootstrap and never the reload script" {
    const sh: Shell = .{
        .title = "T",
        .brand = "B",
        .home_href = "/",
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
