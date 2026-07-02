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

/// The per-page chrome threaded into `wrapPage`: the document title, the sidebar
/// brand text and its home link, the repo-link URL, and the pre-rendered
/// `.sidebar-nav` contents (empty for the project picker).
pub const Shell = struct {
    title: []const u8,
    brand: []const u8,
    home_href: []const u8,
    repo_url: []const u8,
    nav_html: []const u8,
    /// Site default theme/width used as the pre-paint fallback when the reader
    /// has no `localStorage` preference yet. "" means "no default".
    theme: []const u8 = "",
    width: []const u8 = "",
};

/// A minimal shell for standalone rendering with no project/site context
/// (`strike render`): no sidebar nav and no repo link (both degrade to nothing
/// in `wrapPage`), brand falls back to the page's own title.
pub fn standalone(title: []const u8) Shell {
    return .{ .title = title, .brand = title, .home_href = "#", .repo_url = "", .nav_html = "" };
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
    try escapeAttrInto(w, shell.theme);
    try w.writeAll(head_pre_b);
    try escapeAttrInto(w, shell.width);
    try w.writeAll(head_pre_c);
    try escapeInto(w, shell.title);
    try w.writeAll(head_post_a);
    try escapeAttrInto(w, shell.home_href);
    try w.writeAll(head_post_b);
    try escapeInto(w, shell.brand);
    try w.writeAll(head_post_c);
    if (shell.repo_url.len > 0) {
        try w.writeAll(repo_link_pre);
        try escapeAttrInto(w, shell.repo_url);
        try w.writeAll(repo_link_post);
    }
    try w.writeAll(head_post_d);
    try w.writeAll(shell.nav_html);
    try w.writeAll(head_post_e);
    try w.writeAll(body_html);
    try w.writeAll(page_tail);
    return out.toOwnedSlice();
}

// The no-flash bootstrap: it restores theme/width/sidebar before first paint.
// `wrapPage` splices the site default theme then width into the two `||"…"`
// fallbacks so an unset reader gets the site default (still overridable).
const head_pre_a =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<script>(function(){try{var d=document.documentElement;var t=localStorage.getItem("theme")||"
;
const head_pre_b =
    \\";if(t==="light"||t==="dark")d.dataset.theme=t;var w=localStorage.getItem("width")||"
;
const head_pre_c =
    \\";if(w)d.style.setProperty("--content-width",w+"rem");var s=localStorage.getItem("sidebar");if(s==="collapsed")d.dataset.sidebar="collapsed";}catch(e){}})();</script>
    \\<title>
;

// Everything from `</title>` through the opening of `<main>`. Includes the
// MathJax loader, the themed stylesheet, and the fixed-rail sidebar (which holds
// the light/dark toggle button). Color tokens are defined for a light `:root`,
// with dark values applied either by the system preference (when the reader has
// not chosen) or by an explicit `[data-theme]` override set from `localStorage`.
const head_post_a =
    \\</title>
    \\<script>MathJax = { tex: { inlineMath: [['\\(','\\)']], displayMath: [['\\[','\\]']] } };</script>
    \\<script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>
    \\<style>
    \\  :root {
    \\    color-scheme: light;
    \\    --bg: #ffffff; --fg: #1a1a1a; --muted: #5c5c5c; --accent: #2563eb;
    \\    --code-bg: rgba(127,127,127,.14); --border: rgba(127,127,127,.30);
    \\    --sidebar-bg: #f6f7f9;
    \\  }
    \\  @media (prefers-color-scheme: dark) {
    \\    :root:not([data-theme]) {
    \\      color-scheme: dark;
    \\      --bg: #0f1419; --fg: #e6e6e6; --muted: #9aa4b2; --accent: #60a5fa;
    \\      --code-bg: rgba(255,255,255,.08); --border: rgba(255,255,255,.14);
    \\      --sidebar-bg: #11161d;
    \\    }
    \\  }
    \\  :root[data-theme="light"] {
    \\    color-scheme: light;
    \\    --bg: #ffffff; --fg: #1a1a1a; --muted: #5c5c5c; --accent: #2563eb;
    \\    --code-bg: rgba(127,127,127,.14); --border: rgba(127,127,127,.30);
    \\    --sidebar-bg: #f6f7f9;
    \\  }
    \\  :root[data-theme="dark"] {
    \\    color-scheme: dark;
    \\    --bg: #0f1419; --fg: #e6e6e6; --muted: #9aa4b2; --accent: #60a5fa;
    \\    --code-bg: rgba(255,255,255,.08); --border: rgba(255,255,255,.14);
    \\    --sidebar-bg: #11161d;
    \\  }
    \\  * { box-sizing: border-box; }
    \\  body {
    \\    margin: 0; padding-left: 14rem;
    \\    background: var(--bg); color: var(--fg);
    \\    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    \\  }
    \\  .content { max-width: var(--content-width, 44rem); margin: 3rem auto; padding: 0 1.25rem; }
    \\  h1, h2, h3 { line-height: 1.25; }
    \\  code {
    \\    background: var(--code-bg); padding: .15em .35em;
    \\    border-radius: 4px; font-size: .9em;
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
    \\  a { color: var(--accent); }
    \\  hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }
    \\  .sidebar {
    \\    position: fixed; top: 0; left: 0; width: 14rem; height: 100vh;
    \\    display: flex; flex-direction: column; gap: 1rem;
    \\    padding: 1.25rem 1rem;
    \\    background: var(--sidebar-bg); border-right: 1px solid var(--border);
    \\  }
    \\  .sidebar-brand { display: flex; align-items: center; gap: .5rem; font-weight: 600; font-size: 1.05rem; letter-spacing: .02em; }
    \\  .repo-link { display: inline-flex; color: var(--muted); }
    \\  .repo-link:hover { color: var(--accent); }
    \\  .repo-link svg { display: block; }
    \\  .sidebar-nav { flex: 1; min-height: 0; overflow-y: auto; }
    \\  .sidebar-brand { justify-content: space-between; }
    \\  .brand-home { color: inherit; text-decoration: none; }
    \\  .brand-home:hover { color: var(--accent); }
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
    \\  .project-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 1rem; margin-top: 2rem; }
    \\  .project-card { display: flex; flex-direction: column; gap: .35rem; padding: 1.1rem 1.25rem; border: 1px solid var(--border); border-radius: 12px; text-decoration: none; color: var(--fg); background: var(--sidebar-bg); transition: border-color .12s, transform .12s; }
    \\  .project-card:hover { border-color: var(--accent); transform: translateY(-2px); }
    \\  .project-icon { font-size: 1.6rem; }
    \\  .project-title { font-weight: 600; font-size: 1.1rem; }
    \\  .project-desc { color: var(--muted); font-size: .9rem; }
    \\  .theme-toggle {
    \\    display: flex; align-items: center; justify-content: center; gap: .5rem;
    \\    width: 100%; padding: .5rem .75rem; font: inherit; font-size: .9rem;
    \\    color: var(--fg); background: transparent;
    \\    border: 1px solid var(--border); border-radius: 8px; cursor: pointer;
    \\  }
    \\  .theme-toggle:hover { background: var(--code-bg); }
    \\  .sidebar-controls { display: flex; flex-direction: column; gap: .75rem; }
    \\  .control { display: flex; flex-direction: column; gap: .35rem; font-size: .8rem; color: var(--muted); }
    \\  .control-label { display: flex; justify-content: space-between; }
    \\  .width-range { width: 100%; accent-color: var(--accent); cursor: pointer; }
    \\  .sidebar-toggle {
    \\    display: flex; align-items: center; justify-content: center; gap: .5rem;
    \\    width: 100%; padding: .4rem .75rem; font: inherit; font-size: .85rem;
    \\    color: var(--muted); background: transparent;
    \\    border: 1px solid var(--border); border-radius: 8px; cursor: pointer;
    \\  }
    \\  .sidebar-toggle:hover { background: var(--code-bg); color: var(--fg); }
    \\  /* Collapsed: shrink to a thin rail showing only the toggle. */
    \\  :root[data-sidebar="collapsed"] body { padding-left: 3rem; }
    \\  :root[data-sidebar="collapsed"] .sidebar { width: 3rem; padding: 1.25rem .5rem; gap: .5rem; }
    \\  :root[data-sidebar="collapsed"] .sidebar-brand,
    \\  :root[data-sidebar="collapsed"] .sidebar-nav,
    \\  :root[data-sidebar="collapsed"] .sidebar-controls,
    \\  :root[data-sidebar="collapsed"] .theme-toggle { display: none; }
    \\  :root[data-sidebar="collapsed"] .sidebar-toggle { padding: .4rem; }
    \\  @media (max-width: 50rem) {
    \\    body { padding-left: 0; }
    \\    .sidebar {
    \\      position: static; width: auto; height: auto;
    \\      flex-direction: row; align-items: center; justify-content: space-between;
    \\    }
    \\    .sidebar-nav, .sidebar-controls, .sidebar-toggle { display: none; }
    \\    .theme-toggle { width: auto; }
    \\    .content { margin-top: 1.5rem; }
    \\  }
    \\</style>
    \\</head>
    \\<body>
    \\<aside class="sidebar">
    \\  <div class="sidebar-brand">
    \\    <a class="brand-home" href="
;

// `head_post_a` ends mid-attribute so `wrapPage` can splice the brand's home
// `href`, the brand text, the repo-link `href`, and the rendered sidebar nav.
const head_post_b =
    \\">
;
const head_post_c =
    \\</a>
;

// The repo-link anchor itself — spliced in by `wrapPage` only when
// `shell.repo_url` is non-empty, so a standalone page (no repo to link to)
// omits it entirely instead of rendering a link to nowhere.
const repo_link_pre =
    \\    <a class="repo-link" href="
;
const repo_link_post =
    \\" target="_blank" rel="noopener noreferrer" aria-label="Strike repository" title="Strike repository">
    \\      <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>
    \\    </a>
;

const head_post_d =
    \\  </div>
    \\  <nav class="sidebar-nav">
;
const head_post_e =
    \\</nav>
    \\  <div class="sidebar-controls">
    \\    <label class="control" for="width-range">
    \\      <span class="control-label"><span>Width</span><span id="width-value">44rem</span></span>
    \\      <input id="width-range" class="width-range" type="range" min="30" max="72" step="1" value="44">
    \\    </label>
    \\  </div>
    \\  <button id="theme-toggle" class="theme-toggle" type="button" aria-label="Toggle color theme"></button>
    \\  <button id="sidebar-toggle" class="sidebar-toggle" type="button" aria-label="Hide sidebar"></button>
    \\</aside>
    \\<main class="content">
    \\
;

const page_tail =
    \\</main>
    \\<script>
    \\(function(){
    \\  var btn = document.getElementById("theme-toggle");
    \\  if (!btn) return;
    \\  function effective(){
    \\    var t = document.documentElement.dataset.theme;
    \\    if (t === "light" || t === "dark") return t;
    \\    return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    \\  }
    \\  function refresh(){
    \\    btn.textContent = effective() === "dark" ? "☀ Light" : "☾ Dark";
    \\  }
    \\  btn.addEventListener("click", function(){
    \\    var next = effective() === "dark" ? "light" : "dark";
    \\    document.documentElement.dataset.theme = next;
    \\    try { localStorage.setItem("theme", next); } catch (e) {}
    \\    refresh();
    \\  });
    \\  refresh();
    \\
    \\  var range = document.getElementById("width-range");
    \\  var wval = document.getElementById("width-value");
    \\  if (range) {
    \\    var saved = null;
    \\    try { saved = localStorage.getItem("width"); } catch (e) {}
    \\    if (saved) range.value = saved;
    \\    function applyWidth(v){
    \\      document.documentElement.style.setProperty("--content-width", v + "rem");
    \\      if (wval) wval.textContent = v + "rem";
    \\    }
    \\    applyWidth(range.value);
    \\    range.addEventListener("input", function(){
    \\      applyWidth(range.value);
    \\      try { localStorage.setItem("width", range.value); } catch (e) {}
    \\    });
    \\  }
    \\
    \\  var stog = document.getElementById("sidebar-toggle");
    \\  if (stog) {
    \\    function collapsed(){ return document.documentElement.dataset.sidebar === "collapsed"; }
    \\    function srefresh(){
    \\      var c = collapsed();
    \\      stog.textContent = c ? "›" : "‹ Hide";
    \\      stog.setAttribute("aria-label", c ? "Show sidebar" : "Hide sidebar");
    \\      stog.setAttribute("title", c ? "Show sidebar" : "Hide sidebar");
    \\    }
    \\    stog.addEventListener("click", function(){
    \\      var next = collapsed() ? "expanded" : "collapsed";
    \\      if (next === "collapsed") document.documentElement.dataset.sidebar = "collapsed";
    \\      else delete document.documentElement.dataset.sidebar;
    \\      try { localStorage.setItem("sidebar", next); } catch (e) {}
    \\      srefresh();
    \\    });
    \\    srefresh();
    \\  }
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

test "wrapPage emits sidebar, theme toggle and content body" {
    const shell: Shell = .{
        .title = "Doc",
        .brand = "Data Mining",
        .home_href = "/",
        .repo_url = "https://example.com/strike",
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
    // Sidebar with the theme toggle button and the width control.
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"theme-toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"width-range\"") != null);
    // Collapse control plus the no-flash bootstrap that restores its state.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"sidebar-toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-sidebar=\"collapsed\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"sidebar\")") != null);
    // Repository link with the external-link icon next to the brand.
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"repo-link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "target=\"_blank\"") != null);
    // Content width is driven by the CSS variable the slider sets.
    try std.testing.expect(std.mem.indexOf(u8, page, "max-width: var(--content-width, 44rem)") != null);
    // Both the dark override rule and the no-flash bootstrap are wired up.
    try std.testing.expect(std.mem.indexOf(u8, page, ":root[data-theme=\"dark\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "localStorage.getItem(\"theme\")") != null);
}

test "standalone shell has no nav and no repo link" {
    const shell = standalone("My Doc");
    const page = try wrapPage(std.testing.allocator, shell, "<p>hi</p>\n");
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "<title>My Doc</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "brand-home\" href=\"#\">My Doc</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<nav class=\"sidebar-nav\"></nav>") != null);
}

test "empty repo_url omits the repo-link anchor entirely" {
    const shell: Shell = .{ .title = "T", .brand = "B", .home_href = "/", .repo_url = "", .nav_html = "" };
    const page = try wrapPage(std.testing.allocator, shell, "");
    defer std.testing.allocator.free(page);

    // The stylesheet still defines the `.repo-link` class either way; what must
    // be absent is the anchor element itself.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a class=\"repo-link\"") == null);
}
