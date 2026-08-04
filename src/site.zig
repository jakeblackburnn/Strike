//! Turns a loaded `project.Site` into finished HTML pages: the `/` picker, each
//! project's home, and each document, all with their project's sidebar nav.
//!
//! This is the single shared implementation of "render this Site" — both the
//! `serve` and `build` CLI subcommands (`main.zig`) call `renderAll`, so page
//! assembly can't drift between the live server and the static-export path the
//! way it used to.
//!
//! If `site.projects` contains the implicit root project (`slug == ""`, see
//! `project.zig`), its home takes over route `/` instead of the picker — there
//! is nothing to pick between if the content root itself has documents.
//! (`project.load` makes the root project the *only* project — subdirectories
//! nest into its tree — but `renderAll` still renders any sibling projects a
//! hand-built `Site` carries, at their normal `/<slug>` routes.) This mirrors
//! how a docs site's root README naturally becomes the landing page.

const std = @import("std");
const project = @import("project.zig");
const render_html = @import("render_html.zig");
const shell = @import("shell.zig");
const html = @import("html.zig");
const escapeInto = html.escapeInto;
const escapeAttrInto = html.escapeAttrInto;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Shell = shell.Shell;

/// One rendered page: its route, a human-readable source description (for
/// banners/logging), which kind of page it is (needed by `outPath`, since a
/// route alone can't always tell a project home from a document — see the root
/// project above), and the full HTML document. Caller owns `html`.
pub const Page = struct {
    route: []const u8,
    src: []const u8,
    kind: enum { picker, home, doc },
    html: []u8,
};

/// Render every page in `site`: `/` (the picker, or the root project's home if
/// one exists), each other project's home, and each document.
///
/// `arena` follows `project.load`'s contract: a process- or
/// generation-lifetime allocator freed *whole*, never piecemeal — `Page.route`
/// is sometimes allocated and sometimes a borrowed slice of the site, so the
/// pages can't be freed individually.
pub fn renderAll(arena: Allocator, site: project.Site) ![]Page {
    var pages: std.ArrayList(Page) = .empty;

    var root: ?project.Project = null;
    for (site.projects) |p| {
        if (p.slug.len == 0) {
            root = p;
            break;
        }
    }

    if (root) |r| {
        try pages.append(arena, .{ .route = homeHref(site.base), .src = "(root)", .kind = .home, .html = try renderProjectHome(arena, r) });
    } else {
        try pages.append(arena, .{ .route = homeHref(site.base), .src = "(picker)", .kind = .picker, .html = try renderPickerPage(arena, site) });
    }

    for (site.projects) |p| {
        if (p.slug.len == 0) {
            // Its home was already rendered above, at "/"; only its docs
            // (already routed at "/<relpath>", no slug prefix) remain.
            for (p.docs) |d| {
                try pages.append(arena, .{ .route = d.route, .src = d.route[1..], .kind = .doc, .html = try renderDocPage(arena, p, d) });
            }
            try appendFolderPages(arena, &pages, p, p.tree);
            continue;
        }
        try pages.append(arena, .{
            .route = try projectHref(arena, p),
            .src = p.slug,
            .kind = .home,
            .html = try renderProjectHome(arena, p),
        });
        for (p.docs) |d| {
            try pages.append(arena, .{ .route = d.route, .src = d.route[1..], .kind = .doc, .html = try renderDocPage(arena, p, d) });
        }
        try appendFolderPages(arena, &pages, p, p.tree);
    }
    return pages.toOwnedSlice(arena);
}

/// Append a page for every folder carrying a `main.*` doc, served at the
/// folder's own route. Runs after the project's docs so that on a route
/// collision (a folder `x/` with a main.* next to a sibling doc `x.md`) the
/// doc wins deterministically — the folder page is skipped with a warning.
fn appendFolderPages(gpa: Allocator, pages: *std.ArrayList(Page), p: project.Project, nodes: []const project.NavNode) !void {
    for (nodes) |node| switch (node) {
        .folder => |f| {
            if (f.main) |m| {
                if (routeTaken(pages.items, m.route)) {
                    std.debug.print("strike: warning: folder page {s} collides with an existing page; skipping\n", .{m.route});
                } else {
                    try pages.append(gpa, .{ .route = m.route, .src = m.route[1..], .kind = .home, .html = try renderDocPage(gpa, p, m) });
                }
            }
            try appendFolderPages(gpa, pages, p, f.children);
        },
        .doc => {},
    };
}

fn routeTaken(pages: []const Page, route: []const u8) bool {
    for (pages) |pg| if (std.mem.eql(u8, pg.route, route)) return true;
    return false;
}

/// The href of the site's front page: the base path when one is set, else `/`.
pub fn homeHref(base: []const u8) []const u8 {
    return if (base.len > 0) base else "/";
}

/// The href of one project's own root — where its sidebar brand links. A root
/// project (empty slug) *is* the front page; every other project sits at
/// `<base>/<slug>`. Caller owns the result.
pub fn projectHref(gpa: Allocator, p: project.Project) ![]const u8 {
    if (p.slug.len == 0) return gpa.dupe(u8, homeHref(p.base));
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ p.base, p.slug });
}

/// Map a rendered page to its on-disk export path: the front page (picker or
/// root-project home) -> `"index.html"`; a project home -> `"<slug>/index.html"`;
/// a document -> `"<route>.html"`. `base` (the site's base path, "" if none) is
/// stripped first: routes carry it so links work when mounted under a subpath,
/// but the export tree stays relative to the mount point — deploy the output
/// directory *at* the base, don't nest it again. Takes the whole `Page` (not
/// just its route) because a bare route can't distinguish a project home from
/// a document once the root project makes single-segment document routes
/// possible (e.g. `/hello`).
pub fn outPath(gpa: Allocator, page: Page, base: []const u8) ![]u8 {
    var route = page.route;
    if (base.len > 0 and std.mem.startsWith(u8, route, base) and
        (route.len == base.len or route[base.len] == '/'))
    {
        route = route[base.len..];
    }
    if (route.len == 0 or std.mem.eql(u8, route, "/")) return gpa.dupe(u8, "index.html");
    const rel = route[1..];
    return switch (page.kind) {
        .home => std.fmt.allocPrint(gpa, "{s}/index.html", .{rel}),
        // .picker can't actually reach here: a picker's route is always the
        // front page, which the early return above already mapped.
        .doc, .picker => std.fmt.allocPrint(gpa, "{s}.html", .{rel}),
    };
}

/// Render the `/` picker as a full page. The sidebar nav — navigation's home —
/// carries every project *and* its documents, so the whole site is reachable
/// however the body was authored (a root `main.*` fully owns the body content).
/// Caller owns the result.
pub fn renderPickerPage(gpa: Allocator, site: project.Site) ![]u8 {
    const body = try renderPicker(gpa, site);
    defer gpa.free(body);
    const nav = try renderPickerNav(gpa, site);
    defer gpa.free(nav);
    const picker_shell: Shell = .{
        .title = site.title,
        .brand = site.title,
        // The picker is not inside a project; its brand links to itself.
        .home_href = homeHref(site.base),
        .nav_html = nav,
        .season = site.season,
        .time = site.time,
        .width = site.width,
    };
    return shell.wrapPage(gpa, picker_shell, body);
}

/// Render a project's `/<slug>` home page: its configured `home:` doc if set,
/// else a generated index (title, description, and a link list of its docs).
/// Caller owns the result.
pub fn renderProjectHome(gpa: Allocator, p: project.Project) ![]u8 {
    if (p.home) |h| return renderDocPage(gpa, p, h);

    var body: Writer.Allocating = .init(gpa);
    defer body.deinit();
    const w = &body.writer;
    try w.writeAll("<h1>");
    try escapeInto(w, p.title);
    try w.writeAll("</h1>\n");
    if (p.description.len > 0) {
        try w.writeAll("<p>");
        try escapeInto(w, p.description);
        try w.writeAll("</p>\n");
    }
    try w.writeAll("<ul>\n");
    for (p.docs) |d| try writeLinkItem(w, d.route, d.label);
    try w.writeAll("</ul>\n");

    const nav = try renderNav(gpa, p.slug, p.tree, "");
    defer gpa.free(nav);
    const brand_href = try projectHref(gpa, p);
    defer gpa.free(brand_href);
    const home_shell: Shell = .{
        .title = p.title,
        .brand = p.title,
        .home_href = brand_href,
        .site_title = p.site_title,
        .site_href = homeHref(p.base),
        .nav_html = nav,
        .season = p.season,
        .time = p.time,
        .width = p.width,
    };
    return shell.wrapPage(gpa, home_shell, body.written());
}

/// Render a single document into a full page, with its project's nav (the doc
/// marked active) and chrome. Caller owns the result.
pub fn renderDocPage(gpa: Allocator, p: project.Project, d: *project.Doc) ![]u8 {
    const nav = try renderNav(gpa, p.slug, p.tree, d.route);
    defer gpa.free(nav);
    const body = (try render_html.render(gpa, d.md, .{
        .sheet = p.sheet,
        .link_base = d.route_dir,
        .link_floor = p.base,
    })).takeHtml(gpa, d.rel_path);
    defer gpa.free(body);
    const brand_href = try projectHref(gpa, p);
    defer gpa.free(brand_href);
    const doc_shell: Shell = .{
        .title = d.title,
        .brand = p.title,
        .home_href = brand_href,
        .site_title = p.site_title,
        .site_href = homeHref(p.base),
        .nav_html = nav,
        .season = p.season,
        .time = p.time,
        .width = p.width,
    };
    return shell.wrapPage(gpa, doc_shell, body);
}

/// Render the inner HTML of `.sidebar-nav` for one project: a nested tree of
/// folders (`<details>`) and document links, with the `active_route` doc marked
/// and its ancestor folders rendered open. `slug` keys per-folder collapse state
/// in `localStorage`. Returns "" for an empty tree. Caller owns the result.
pub fn renderNav(allocator: Allocator, slug: []const u8, tree: []const project.NavNode, active_route: []const u8) ![]u8 {
    if (tree.len == 0) return allocator.dupe(u8, "");
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try renderNavList(&out.writer, slug, tree, active_route);
    return out.toOwnedSlice();
}

fn renderNavList(w: *Writer, slug: []const u8, nodes: []const project.NavNode, active: []const u8) Writer.Error!void {
    try w.writeAll("<ul class=\"nav-tree\">");
    for (nodes) |node| switch (node) {
        .doc => |d| {
            const is_active = std.mem.eql(u8, d.route, active);
            try w.writeAll(if (is_active) "<li><a class=\"nav-doc active\" aria-current=\"page\" href=\"" else "<li><a class=\"nav-doc\" href=\"");
            try escapeAttrInto(w, d.route);
            try w.writeAll("\">");
            try escapeInto(w, d.label);
            try w.writeAll("</a></li>");
        },
        .folder => |f| {
            const own_active = if (f.main) |m| std.mem.eql(u8, m.route, active) else false;
            const open = own_active or navContainsActive(f.children, active);
            try w.writeAll("<li><details class=\"nav-folder\" data-folder=\"");
            try escapeAttrInto(w, slug);
            try w.writeByte('/');
            try escapeAttrInto(w, f.rel_path);
            try w.writeAll(if (open) "\" open><summary>" else "\"><summary>");
            if (f.main) |m| {
                // The folder has its own page (a main.*): the label is a link.
                try w.writeAll(if (own_active)
                    "<a class=\"nav-folder-link active\" aria-current=\"page\" href=\""
                else
                    "<a class=\"nav-folder-link\" href=\"");
                try escapeAttrInto(w, m.route);
                try w.writeAll("\">");
                try escapeInto(w, f.label);
                try w.writeAll("</a>");
            } else {
                try escapeInto(w, f.label);
            }
            try w.writeAll("</summary>");
            try renderNavList(w, slug, f.children, active);
            try w.writeAll("</details></li>");
        },
    };
    try w.writeAll("</ul>");
}

/// True if any descendant document (or folder page) of `nodes` is the active route.
fn navContainsActive(nodes: []const project.NavNode, active: []const u8) bool {
    for (nodes) |node| switch (node) {
        .doc => |d| if (std.mem.eql(u8, d.route, active)) return true,
        .folder => |f| {
            if (f.main) |m| if (std.mem.eql(u8, m.route, active)) return true;
            if (navContainsActive(f.children, active)) return true;
        },
    };
    return false;
}

/// The picker page's sidebar nav: the whole site, one expandable node per
/// project. Each project is the same `<details class="nav-folder">` a folder
/// inside a project gets — its summary links the project home, its children are
/// that project's own tree — so the picker reaches every document directly
/// instead of bouncing the reader through a project home first. Open by default
/// (the front page's job is to show what's there); `data-folder` is the bare
/// slug, which no folder key can collide with since those always carry a `/`,
/// so a reader's collapse survives in `localStorage` like any other folder.
/// A project with no documents of its own stays a plain link. Returns "" when
/// there are no projects. Caller owns the result.
pub fn renderPickerNav(allocator: Allocator, site: project.Site) ![]u8 {
    if (site.projects.len == 0) return allocator.dupe(u8, "");
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<ul class=\"nav-tree\">");
    for (site.projects) |p| {
        if (p.tree.len == 0) {
            try w.writeAll("<li><a class=\"nav-doc\" href=\"");
            try writeProjectHref(w, site.base, p.slug);
            try w.writeAll("\">");
            try escapeInto(w, p.title);
            try w.writeAll("</a></li>");
            continue;
        }
        try w.writeAll("<li><details class=\"nav-folder\" data-folder=\"");
        try escapeAttrInto(w, p.slug);
        try w.writeAll("\" open><summary><a class=\"nav-folder-link\" href=\"");
        try writeProjectHref(w, site.base, p.slug);
        try w.writeAll("\">");
        try escapeInto(w, p.title);
        try w.writeAll("</a></summary>");
        try renderNavList(w, p.slug, p.tree, "");
        try w.writeAll("</details></li>");
    }
    try w.writeAll("</ul>");
    return out.toOwnedSlice();
}

fn writeProjectHref(w: *Writer, base: []const u8, slug: []const u8) Writer.Error!void {
    try escapeAttrInto(w, base);
    try w.writeByte('/');
    try escapeAttrInto(w, slug);
}

/// One escaped `<li><a href="…">label</a></li>` body-list entry — the shared
/// shape of every generated link list (project home index, picker default).
fn writeLinkItem(w: *Writer, href: []const u8, label: []const u8) Writer.Error!void {
    try w.writeAll("<li><a href=\"");
    try escapeAttrInto(w, href);
    try w.writeAll("\">");
    try escapeInto(w, label);
    try w.writeAll("</a></li>\n");
}

/// Render the body fragment for the `/` project picker. A content-root
/// `main.*` dictates the whole page when present; otherwise a minimal
/// default: the site-title heading and a plain link list of the projects.
/// Caller owns the result.
pub fn renderPicker(allocator: Allocator, site: project.Site) ![]u8 {
    if (site.main) |m| {
        const r = try render_html.render(allocator, m.md, .{
            .sheet = site.sheet,
            .link_base = m.route_dir,
            .link_floor = site.base,
        });
        return r.takeHtml(allocator, m.rel_path);
    }

    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<h1>");
    try escapeInto(w, site.title);
    try w.writeAll("</h1>\n<ul>\n");
    for (site.projects) |p| {
        const href = try projectHref(allocator, p);
        defer allocator.free(href);
        try writeLinkItem(w, href, p.title);
    }
    try w.writeAll("</ul>\n");
    return out.toOwnedSlice();
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn testDoc(route: []const u8, label: []const u8) project.Doc {
    return .{ .rel_path = route, .route = route, .label = label, .title = label, .md = "" };
}

test "renderNav marks the active doc and opens its ancestor folder" {
    var leaf = testDoc("/p/topo/a", "A");
    var sibling = testDoc("/p/topo/b", "B");
    var children = [_]project.NavNode{ .{ .doc = &leaf }, .{ .doc = &sibling } };
    var tree = [_]project.NavNode{
        .{ .folder = .{ .label = "Topo", .rel_path = "topo", .children = &children } },
    };
    const nav = try renderNav(testing.allocator, "p", &tree, "/p/topo/a");
    defer testing.allocator.free(nav);

    try testing.expect(std.mem.indexOf(u8, nav, "<details class=\"nav-folder\" data-folder=\"p/topo\" open>") != null);
    try testing.expect(std.mem.indexOf(u8, nav, "class=\"nav-doc active\" aria-current=\"page\" href=\"/p/topo/a\">A</a>") != null);
    try testing.expect(std.mem.indexOf(u8, nav, "class=\"nav-doc\" href=\"/p/topo/b\">B</a>") != null);
}

test "renderNav returns empty string for an empty tree" {
    const nav = try renderNav(testing.allocator, "p", &.{}, "");
    defer testing.allocator.free(nav);
    try testing.expectEqualStrings("", nav);
}

test "renderPicker default is a heading and a plain link list" {
    var projects = [_]project.Project{
        .{ .slug = "a", .title = "A & Co", .description = "desc", .season = "", .time = "", .width = "", .home = null, .tree = &.{}, .docs = &.{} },
        .{ .slug = "b", .title = "B", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &.{}, .docs = &.{} },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects };
    const body = try renderPicker(testing.allocator, site);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "<h1>Site</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<li><a href=\"/a\">A &amp; Co</a></li>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<li><a href=\"/b\">B</a></li>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "project-") == null); // no cards
}

test "renderProjectHome escapes generated-index title, description and labels" {
    var doc = testDoc("/p/a", "A & B");
    var docs = [_]*project.Doc{&doc};
    var tree = [_]project.NavNode{.{ .doc = &doc }};
    const p: project.Project = .{
        .slug = "p",
        .title = "Title <script>",
        .description = "desc & more",
        .season = "",
        .time = "",
        .width = "",
        .home = null,
        .tree = &tree,
        .docs = &docs,
    };
    const page = try renderProjectHome(testing.allocator, p);
    defer testing.allocator.free(page);

    try testing.expect(std.mem.indexOf(u8, page, "<h1>Title &lt;script&gt;</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<p>desc &amp; more</p>") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<li><a href=\"/p/a\">A &amp; B</a></li>") != null);
}

test "renderAll renders the picker, each project home, and each doc" {
    var doc1 = testDoc("/a/one", "One");
    var doc2 = testDoc("/b/two", "Two");
    var a_docs = [_]*project.Doc{&doc1};
    var b_docs = [_]*project.Doc{&doc2};
    var a_tree = [_]project.NavNode{.{ .doc = &doc1 }};
    var b_tree = [_]project.NavNode{.{ .doc = &doc2 }};
    var projects = [_]project.Project{
        .{ .slug = "a", .title = "A", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &a_tree, .docs = &a_docs },
        .{ .slug = "b", .title = "B", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &b_tree, .docs = &b_docs },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects };

    // `renderAll`'s `Page.route` is a mix of allocated (project homes) and
    // borrowed (picker's "/", docs' `Doc.route`) strings — the same
    // never-free-piecemeal contract `main.zig`/`build.zig` rely on. An arena
    // matches that contract instead of fighting it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pages = try renderAll(arena.allocator(), site);

    // picker + 2 project homes + 2 docs
    try testing.expectEqual(@as(usize, 5), pages.len);
    try testing.expectEqualStrings("/", pages[0].route);
    try testing.expectEqual(.picker, pages[0].kind);
    try testing.expectEqualStrings("/a", pages[1].route);
    try testing.expectEqual(.home, pages[1].kind);
    try testing.expectEqualStrings("/a/one", pages[2].route);
    try testing.expectEqual(.doc, pages[2].kind);
    try testing.expectEqualStrings("/b", pages[3].route);
    try testing.expectEqualStrings("/b/two", pages[4].route);
}

test "renderAll gives the root project's home route \"/\" instead of a picker" {
    var root_doc = testDoc("/hello", "Hello");
    var sub_doc = testDoc("/blog/post", "Post");
    var root_docs = [_]*project.Doc{&root_doc};
    var sub_docs = [_]*project.Doc{&sub_doc};
    var root_tree = [_]project.NavNode{.{ .doc = &root_doc }};
    var sub_tree = [_]project.NavNode{.{ .doc = &sub_doc }};
    var projects = [_]project.Project{
        .{ .slug = "", .title = "Site", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &root_tree, .docs = &root_docs },
        .{ .slug = "blog", .title = "Blog", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &sub_tree, .docs = &sub_docs },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pages = try renderAll(arena.allocator(), site);

    // root home ("/") + root doc ("/hello") + blog home ("/blog") + blog doc — no separate picker page.
    try testing.expectEqual(@as(usize, 4), pages.len);
    try testing.expectEqualStrings("/", pages[0].route);
    try testing.expectEqual(.home, pages[0].kind);
    try testing.expect(std.mem.indexOf(u8, pages[0].html, "<li><a href=\"/hello\">Hello</a></li>") != null);
    try testing.expectEqualStrings("/hello", pages[1].route);
    try testing.expectEqualStrings("/blog", pages[2].route);
    try testing.expectEqualStrings("/blog/post", pages[3].route);
}

test "renderAll emits a folder page for a folder with a main.*" {
    var doc = testDoc("/p/sub/a", "A");
    var folder_main = testDoc("/p/sub", "Sub");
    var children = [_]project.NavNode{.{ .doc = &doc }};
    var tree = [_]project.NavNode{
        .{ .folder = .{ .label = "Sub", .rel_path = "sub", .children = &children, .main = &folder_main } },
    };
    var docs = [_]*project.Doc{&doc};
    var projects = [_]project.Project{
        .{ .slug = "p", .title = "P", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &tree, .docs = &docs },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pages = try renderAll(arena.allocator(), site);

    // picker + project home + doc + folder page
    try testing.expectEqual(@as(usize, 4), pages.len);
    try testing.expectEqualStrings("/p/sub", pages[3].route);
    try testing.expectEqual(.home, pages[3].kind); // exports to p/sub/index.html
}

test "renderNav links a folder's label to its main page and marks it active" {
    var doc = testDoc("/p/sub/a", "A");
    var folder_main = testDoc("/p/sub", "Sub");
    var children = [_]project.NavNode{.{ .doc = &doc }};
    var tree = [_]project.NavNode{
        .{ .folder = .{ .label = "Sub", .rel_path = "sub", .children = &children, .main = &folder_main } },
    };
    const nav = try renderNav(testing.allocator, "p", &tree, "/p/sub");
    defer testing.allocator.free(nav);

    try testing.expect(std.mem.indexOf(u8, nav, "<a class=\"nav-folder-link active\" aria-current=\"page\" href=\"/p/sub\">Sub</a>") != null);
    // the folder page being active also opens the folder
    try testing.expect(std.mem.indexOf(u8, nav, "data-folder=\"p/sub\" open>") != null);
}

test "picker page sidebar nav links a project with no documents plainly" {
    var projects = [_]project.Project{
        .{ .slug = "a", .title = "A", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &.{}, .docs = &.{} },
        .{ .slug = "b", .title = "B", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &.{}, .docs = &.{} },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects };
    const page = try renderPickerPage(testing.allocator, site);
    defer testing.allocator.free(page);

    // Nothing to expand into, so no <details> — just the two project links.
    try testing.expect(std.mem.indexOf(u8, page, "<nav class=\"sidebar-nav\"><ul class=\"nav-tree\"><li><a class=\"nav-doc\" href=\"/a\">A</a></li><li><a class=\"nav-doc\" href=\"/b\">B</a></li></ul></nav>") != null);
}

test "picker page sidebar nav expands each project into its own tree" {
    var one = testDoc("/a/one", "One");
    var nested = testDoc("/a/sub/deep", "Deep");
    var two = testDoc("/b/two", "Two");
    var a_children = [_]project.NavNode{.{ .doc = &nested }};
    var a_docs = [_]*project.Doc{ &one, &nested };
    var a_tree = [_]project.NavNode{
        .{ .doc = &one },
        .{ .folder = .{ .label = "Sub", .rel_path = "sub", .children = &a_children } },
    };
    var b_docs = [_]*project.Doc{&two};
    var b_tree = [_]project.NavNode{.{ .doc = &two }};
    var projects = [_]project.Project{
        .{ .slug = "a", .title = "A", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &a_tree, .docs = &a_docs },
        .{ .slug = "b", .title = "B", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &b_tree, .docs = &b_docs },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects };
    const nav = try renderPickerNav(testing.allocator, site);
    defer testing.allocator.free(nav);

    // Each project is a folder node keyed by its bare slug, open by default,
    // its summary linking the project home.
    try testing.expect(std.mem.indexOf(u8, nav, "<details class=\"nav-folder\" data-folder=\"a\" open><summary><a class=\"nav-folder-link\" href=\"/a\">A</a></summary>") != null);
    try testing.expect(std.mem.indexOf(u8, nav, "data-folder=\"b\" open>") != null);
    // Every document is reachable from the front page, nesting included.
    try testing.expect(std.mem.indexOf(u8, nav, "href=\"/a/one\">One</a>") != null);
    try testing.expect(std.mem.indexOf(u8, nav, "data-folder=\"a/sub\"") != null);
    try testing.expect(std.mem.indexOf(u8, nav, "href=\"/a/sub/deep\">Deep</a>") != null);
    try testing.expect(std.mem.indexOf(u8, nav, "href=\"/b/two\">Two</a>") != null);
    // No document is active on the picker.
    try testing.expect(std.mem.indexOf(u8, nav, "active") == null);
}

test "a picker site's brand leads with the site title" {
    var doc = testDoc("/blog/post", "Post");
    var docs = [_]*project.Doc{&doc};
    var tree = [_]project.NavNode{.{ .doc = &doc }};
    var p: project.Project = .{
        .slug = "blog",
        .title = "Blog",
        .description = "",
        .season = "",
        .time = "",
        .width = "",
        .site_title = "Site",
        .home = null,
        .tree = &tree,
        .docs = &docs,
    };
    // The sidebar nav below is one project's tree, so the site segment is the
    // only way back to `/` from a document.
    const page = try renderDocPage(testing.allocator, p, &doc);
    defer testing.allocator.free(page);
    try testing.expect(std.mem.indexOf(u8, page, "<a class=\"brand-site\" href=\"/\">Site</a><span class=\"brand-sep\">/</span><a class=\"brand-home\" href=\"/blog\">Blog</a>") != null);

    // Root-project mode leaves it off: `site_title` is unset, so the brand is
    // the single link it always was.
    p.site_title = "";
    const plain = try renderDocPage(testing.allocator, p, &doc);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "<a class=\"brand-site\"") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "<div class=\"sidebar-brand\"><a class=\"brand-home\" href=\"/blog\">Blog</a></div>") != null);
}

test "renderPicker: site main.* dictates the entire page" {
    var main_doc = testDoc("/", "Intro");
    main_doc.md = "# Intro\n\nwelcome";
    var projects = [_]project.Project{
        .{ .slug = "a", .title = "A", .description = "", .season = "", .time = "", .width = "", .home = null, .tree = &.{}, .docs = &.{} },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .projects = &projects, .main = &main_doc };
    const body = try renderPicker(testing.allocator, site);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "<h1 id=\"intro\">Intro</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<p>welcome</p>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<h1>Site</h1>") == null);
    try testing.expect(std.mem.indexOf(u8, body, "href=\"/a\"") == null); // no generated list
}

test "outPath maps pages to export paths" {
    const picker = try outPath(testing.allocator, .{ .route = "/", .src = "", .kind = .picker, .html = &.{} }, "");
    defer testing.allocator.free(picker);
    try testing.expectEqualStrings("index.html", picker);

    const home = try outPath(testing.allocator, .{ .route = "/pchem", .src = "", .kind = .home, .html = &.{} }, "");
    defer testing.allocator.free(home);
    try testing.expectEqualStrings("pchem/index.html", home);

    const doc = try outPath(testing.allocator, .{ .route = "/pchem/quantum", .src = "", .kind = .doc, .html = &.{} }, "");
    defer testing.allocator.free(doc);
    try testing.expectEqualStrings("pchem/quantum.html", doc);

    const nested = try outPath(testing.allocator, .{ .route = "/data_mining/topo/algebra", .src = "", .kind = .doc, .html = &.{} }, "");
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("data_mining/topo/algebra.html", nested);

    // A root-project doc's route has just one segment ("/hello") but must not
    // be mistaken for a project home ("hello/index.html") — this is exactly
    // the ambiguity `outPath` takes a `Page` (not a bare route) to resolve.
    const root_doc = try outPath(testing.allocator, .{ .route = "/hello", .src = "", .kind = .doc, .html = &.{} }, "");
    defer testing.allocator.free(root_doc);
    try testing.expectEqualStrings("hello.html", root_doc);

    // The root project's own home is "/", same as the picker.
    const root_home = try outPath(testing.allocator, .{ .route = "/", .src = "", .kind = .home, .html = &.{} }, "");
    defer testing.allocator.free(root_home);
    try testing.expectEqualStrings("index.html", root_home);
}

test "outPath strips the site base so exports stay mount-point-relative" {
    const front = try outPath(testing.allocator, .{ .route = "/docs", .src = "", .kind = .picker, .html = &.{} }, "/docs");
    defer testing.allocator.free(front);
    try testing.expectEqualStrings("index.html", front);

    const home = try outPath(testing.allocator, .{ .route = "/docs/pchem", .src = "", .kind = .home, .html = &.{} }, "/docs");
    defer testing.allocator.free(home);
    try testing.expectEqualStrings("pchem/index.html", home);

    const doc = try outPath(testing.allocator, .{ .route = "/docs/pchem/quantum", .src = "", .kind = .doc, .html = &.{} }, "/docs");
    defer testing.allocator.free(doc);
    try testing.expectEqualStrings("pchem/quantum.html", doc);

    // a route that merely shares the base's prefix is not stripped
    const lookalike = try outPath(testing.allocator, .{ .route = "/docsy", .src = "", .kind = .doc, .html = &.{} }, "/docs");
    defer testing.allocator.free(lookalike);
    try testing.expectEqualStrings("docsy.html", lookalike);
}

test "renderAll routes and picker links carry the site base" {
    var doc = testDoc("/docs/a/one", "One");
    var docs = [_]*project.Doc{&doc};
    var tree = [_]project.NavNode{.{ .doc = &doc }};
    var projects = [_]project.Project{
        .{ .slug = "a", .title = "A", .description = "", .season = "", .time = "", .width = "", .base = "/docs", .home = null, .tree = &tree, .docs = &docs },
    };
    const site: project.Site = .{ .title = "Site", .season = "", .time = "", .width = "", .base = "/docs", .projects = &projects };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pages = try renderAll(arena.allocator(), site);

    try testing.expectEqualStrings("/docs", pages[0].route); // the front page
    try testing.expectEqual(.picker, pages[0].kind);
    try testing.expectEqualStrings("/docs/a", pages[1].route);
    // The picker links each project under the base; the picker's own brand
    // links to the front page, since the picker sits in no project.
    try testing.expect(std.mem.indexOf(u8, pages[0].html, "href=\"/docs/a\"") != null);
    try testing.expect(std.mem.indexOf(u8, pages[0].html, "class=\"brand-home\" href=\"/docs\"") != null);
    // A project page's brand links to that project's root, base included.
    try testing.expect(std.mem.indexOf(u8, pages[1].html, "class=\"brand-home\" href=\"/docs/a\"") != null);
}

test "the sidebar brand links to the current project's root" {
    var doc = testDoc("/blog/post", "Post");
    var docs = [_]*project.Doc{&doc};
    var tree = [_]project.NavNode{.{ .doc = &doc }};
    const p: project.Project = .{
        .slug = "blog",
        .title = "Blog",
        .description = "",
        .season = "",
        .time = "",
        .width = "",
        .home = null,
        .tree = &tree,
        .docs = &docs,
    };
    // From a document deep in the project, the brand still points at /blog —
    // not at the site root, and not at the document.
    const page = try renderDocPage(testing.allocator, p, &doc);
    defer testing.allocator.free(page);
    try testing.expect(std.mem.indexOf(u8, page, "class=\"brand-home\" href=\"/blog\">Blog</a>") != null);

    // A root project *is* the front page, so its brand links there.
    var root_doc = testDoc("/hello", "Hello");
    var root_docs = [_]*project.Doc{&root_doc};
    var root_tree = [_]project.NavNode{.{ .doc = &root_doc }};
    const root: project.Project = .{
        .slug = "",
        .title = "Site",
        .description = "",
        .season = "",
        .time = "",
        .width = "",
        .home = null,
        .tree = &root_tree,
        .docs = &root_docs,
    };
    const root_page = try renderDocPage(testing.allocator, root, &root_doc);
    defer testing.allocator.free(root_page);
    try testing.expect(std.mem.indexOf(u8, root_page, "class=\"brand-home\" href=\"/\">Site</a>") != null);
}
