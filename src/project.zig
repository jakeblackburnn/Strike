//! Turns a content folder into a `Site` of self-contained `Project`s, each with
//! a navigable folder/document tree.
//!
//! Layout model (see CLAUDE.md): every *top-level folder* is a project; its
//! `.md`/`.sx` files (recursively, through subfolders) are its documents. A
//! project may carry a `strike.yaml` that overrides nav labels, ordering,
//! hidden paths, the home document, and display metadata; a site-level
//! `strike.yaml` (at the content root) carries the picker title, default repo
//! link, theme, width, and project order. Everything auto-discovers without any
//! YAML.
//!
//! If the content root itself has `.md`/`.sx` files directly inside (a "flat"
//! layout, or loose docs alongside project folders), those are scanned as an
//! implicit **root project** (`Project.slug == ""`) using the exact same
//! `loadProject`/`scan` machinery as any other project. `site.zig`'s `renderAll`
//! gives the root project's home route `/` instead of the cross-project picker
//! (there's nothing to pick between if the root itself has content) — see its
//! doc comment. The root project's `strike.yaml` is the same file as the site's
//! (both live at the content root), so it doubles as both scopes at once.
//!
//! A file named `main.md`/`main.sx` supplies the *content* for the directory
//! containing it without changing structure (yaml stays the source of truth
//! for labels/order/hidden/home). It's excluded from nav and the routed doc
//! list; instead it becomes the project's home when yaml `home:` doesn't
//! override, a subfolder's page at the folder's own route (`Folder.main`), or
//! — at the content root in picker mode — the picker's intro content
//! (`Site.main`). `main.sx` beats `main.md` when both exist.
//!
//! The recursive directory walk does I/O; the tree-shaping/labelling helpers
//! (`prettify`, `firstHeading`, ordering) are pure and unit-tested below.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml.zig");
const sheet = @import("sheet.zig");

pub const Doc = struct {
    rel_path: []const u8, // project-relative, e.g. "topo/algebra.md"
    route: []const u8, // full route, e.g. "/data_mining/topo/algebra"
    label: []const u8, // sidebar nav label
    title: []const u8, // page <title> (first H1, else label)
    md: []const u8, // file contents, kept for rendering
};

pub const Folder = struct {
    label: []const u8,
    rel_path: []const u8, // project-relative, e.g. "topo/algo_ref"
    children: []NavNode,
    /// The folder's `main.md`/`main.sx` content doc, if any: the page served
    /// at the folder's own route. Not part of `children` or `Project.docs`.
    main: ?*Doc = null,
};

pub const NavNode = union(enum) {
    folder: Folder,
    doc: *Doc,

    fn relPath(self: NavNode) []const u8 {
        return switch (self) {
            .folder => |f| f.rel_path,
            .doc => |d| d.rel_path,
        };
    }
};

pub const Project = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8, // "" if none
    repo: []const u8,
    season: []const u8, // site default theme season ("", "fall", ...)
    time: []const u8, // site default theme time ("", "morning", "evening")
    width: []const u8, // site default content width ("" or bare rem number)
    base: []const u8 = "", // site base path ("" or "/sub/path"), copied like theme/width
    home: ?*Doc, // doc served at /<slug>; null ⇒ generated index
    tree: []NavNode,
    docs: []*Doc, // flat list, for route building
    /// The project's typography sheet: the site `header:` .sxh layered under
    /// the project's own (see yaml `header:`). Seeds every document's parse.
    sheet: sheet.Sheet = .empty,
};

pub const Site = struct {
    title: []const u8,
    repo: []const u8,
    season: []const u8, // "" or a season name ("fall", "winter", "spring", "summer")
    time: []const u8, // "" (auto), "morning", or "evening"
    width: []const u8, // "" or a bare number (rem)
    /// Site base path for mounting under a subpath of an existing website:
    /// "" (serve at the domain root, the default) or "/sub/path". Baked into
    /// every route at scan time; `site.outPath` strips it again so the static
    /// export stays relative to the mount point. From the site yaml `base:`.
    base: []const u8 = "",
    projects: []Project,
    /// A content-root `main.*` in picker mode (no root project): rendered at
    /// the top of the picker page in place of the default site-title heading.
    /// (In root-project mode the root scan claims it as that project's home.)
    main: ?*Doc = null,
    /// The site-level typography sheet (yaml `header:` at the content root);
    /// used for the picker intro. Projects carry their own layered copy.
    sheet: sheet.Sheet = .empty,
};

const default_repo = "https://example.com/strike";

/// Per-project parsed config + the accumulating document list, threaded through
/// the recursive scan.
const ProjCtx = struct {
    gpa: Allocator,
    io: std.Io,
    slug: []const u8,
    cfg: yaml.Value, // project strike.yaml (empty map if absent)
    labels: ?yaml.Value,
    order: ?[]const yaml.Value,
    hidden: ?[]const yaml.Value,
    docs: std.ArrayList(*Doc),
    /// True while scanning the implicit root project. Every top-level
    /// directory is *always* its own project (the layout model above), so the
    /// root project's own tree must never recurse into one — otherwise a
    /// sibling project's files would be scanned twice: once nested under the
    /// root project, once as that project's own docs.
    is_root: bool,
};

/// Scan `content` (an opened, iterable content dir) into a `Site`. All
/// returned memory is owned by `gpa`; callers pass a process- or build-lifetime
/// allocator and never free piecemeal.
pub fn load(io: std.Io, gpa: Allocator, content: std.Io.Dir) !Site {
    const site_cfg = readConfig(io, gpa, content, "strike.yaml");
    const base = try normalizeBase(gpa, site_cfg.getScalar("base") orelse "");
    const site_sheet = loadHeader(io, gpa, content, site_cfg);

    // Collect top-level project folders, and note whether the root itself has
    // documents directly inside (the implicit root project, if any).
    var slugs: std.ArrayList([]const u8) = .empty;
    var has_root_docs = false;
    var root_main_name: ?[]const u8 = null;
    var it = content.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (entry.name.len == 0 or entry.name[0] == '.') continue;
                try slugs.append(gpa, try gpa.dupe(u8, entry.name));
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".md") and !std.mem.endsWith(u8, entry.name, ".sx"))
                    continue;
                // main.* is structure-neutral: it alone doesn't put the root
                // into root-project mode (it only supplies content for `/`).
                if (std.mem.eql(u8, stripExtension(entry.name), "main")) {
                    if (root_main_name == null or std.mem.endsWith(u8, entry.name, ".sx"))
                        root_main_name = try gpa.dupe(u8, entry.name);
                } else has_root_docs = true;
            },
            else => {},
        }
    }
    orderSlugs(slugs.items, site_cfg.getList("projects"));

    var projects: std.ArrayList(Project) = .empty;
    if (has_root_docs) {
        if (try loadProject(io, gpa, content, "", site_cfg, base, site_sheet)) |root| try projects.append(gpa, root);
    }
    for (slugs.items) |slug| {
        const p = try loadProject(io, gpa, content, slug, site_cfg, base, site_sheet) orelse continue;
        try projects.append(gpa, p);
    }

    // In picker mode a content-root main.* still supplies the picker's intro
    // content; in root-project mode the root scan already claimed it as the
    // root project's home.
    var site_main: ?*Doc = null;
    if (!has_root_docs) {
        if (root_main_name) |name| site_main = readMainDoc(io, gpa, content, name, "/") catch null;
    }

    const theme = parseTheme(site_cfg.getScalar("theme") orelse "");
    return .{
        .title = site_cfg.getScalar("title") orelse "strikedown",
        .repo = site_cfg.getScalar("repo") orelse default_repo,
        .season = theme.season,
        .time = theme.time,
        .width = site_cfg.getScalar("width") orelse "",
        .base = base,
        .projects = try projects.toOwnedSlice(gpa),
        .main = site_main,
        .sheet = site_sheet,
    };
}

/// Load one project rooted at `content/<slug>`, or — when `slug` is `""` — the
/// content root itself (the implicit root project; see the module doc comment).
/// `base` is the already-normalized site base path ("" or "/sub/path").
fn loadProject(io: std.Io, gpa: Allocator, content: std.Io.Dir, slug: []const u8, site_cfg: yaml.Value, base: []const u8, site_sheet: sheet.Sheet) !?Project {
    const is_root = slug.len == 0;
    var dir = if (is_root) content else content.openDir(io, slug, .{ .iterate = true }) catch return null;
    defer if (!is_root) dir.close(io);

    const cfg = readConfig(io, gpa, dir, "strike.yaml");
    // The root project's strike.yaml *is* the site one, so its header is
    // already in site_sheet; other projects layer theirs on top.
    const proj_sheet = if (is_root)
        site_sheet
    else
        try sheet.concat(gpa, site_sheet, loadHeader(io, gpa, dir, cfg));
    var ctx: ProjCtx = .{
        .gpa = gpa,
        .io = io,
        .slug = slug,
        .cfg = cfg,
        .labels = cfg.get("labels"),
        .order = cfg.getList("order"),
        .hidden = cfg.getList("hidden"),
        .docs = .empty,
        .is_root = is_root,
    };

    // `base` for the root project (so `scan`'s "{prefix}/{rel}" route-building
    // yields "/hello" — or "/docs/hello" under a base — never a doubled
    // slash), `{base}/{slug}` otherwise.
    const route_prefix = if (is_root) base else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, slug });
    const res = try scan(&ctx, dir, "", route_prefix);

    // Resolve the home document: yaml `home:` wins when it resolves (it may
    // name the main.* file itself); else the project root's main.*, if any.
    var home: ?*Doc = null;
    if (cfg.getScalar("home")) |h| {
        for (ctx.docs.items) |d| {
            if (std.mem.eql(u8, d.rel_path, h)) {
                home = d;
                break;
            }
        }
        if (home == null) {
            if (res.main) |m| {
                if (std.mem.eql(u8, m.rel_path, h)) home = m;
            }
        }
    }
    if (home == null) home = res.main;

    // The root project has no folder name to prettify, so it falls back to the
    // site's own title instead — it's serving as the site's front page.
    const default_title = if (is_root) site_cfg.getScalar("title") orelse "strikedown" else try prettify(gpa, slug);
    const site_theme = parseTheme(site_cfg.getScalar("theme") orelse "");

    return .{
        .slug = slug,
        .title = cfg.getScalar("title") orelse default_title,
        .description = cfg.getScalar("description") orelse "",
        .repo = cfg.getScalar("repo") orelse site_cfg.getScalar("repo") orelse default_repo,
        .season = site_theme.season,
        .time = site_theme.time,
        .width = site_cfg.getScalar("width") orelse "",
        .base = base,
        .home = home,
        .tree = res.nodes,
        .docs = try ctx.docs.toOwnedSlice(gpa),
        .sheet = proj_sheet,
    };
}

const ScanResult = struct {
    nodes: []NavNode,
    /// This directory's own `main.md`/`main.sx` doc (not a descendant's).
    main: ?*Doc,
};

/// Recursively scan `dir`, returning this level's ordered nav children (plus
/// its own main.* doc, if any) and appending discovered documents to
/// `ctx.docs`. main.* files are content, not structure: they get the
/// *containing directory's* route and join neither the nav nor `ctx.docs`.
fn scan(ctx: *ProjCtx, dir: std.Io.Dir, rel_prefix: []const u8, route_prefix: []const u8) Allocator.Error!ScanResult {
    const gpa = ctx.gpa;
    var nodes: std.ArrayList(NavNode) = .empty;
    var main_doc: ?*Doc = null;
    var main_is_sx = false;

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "strike.yaml")) continue;
        const name = gpa.dupe(u8, entry.name) catch continue;
        const rel = try joinRel(gpa, rel_prefix, name);
        if (isHidden(ctx, rel)) continue;

        switch (entry.kind) {
            .directory => {
                // Every top-level directory is always its own project (never
                // a subfolder of the root project) — see `ProjCtx.is_root`.
                if (ctx.is_root and rel_prefix.len == 0) continue;
                var sub = dir.openDir(ctx.io, name, .{ .iterate = true }) catch continue;
                defer sub.close(ctx.io);
                const sub_res = try scan(ctx, sub, rel, route_prefix);
                if (sub_res.nodes.len == 0 and sub_res.main == null) continue; // skip empty folders
                try nodes.append(gpa, .{ .folder = .{
                    .label = labelFor(ctx, rel) orelse try prettify(gpa, name),
                    .rel_path = rel,
                    .children = sub_res.nodes,
                    .main = sub_res.main,
                } });
            },
            .file => {
                // Only `.md`/`.sx` are documents; anything else isn't and is
                // skipped (the server may still serve it as a static asset).
                const is_sx = std.mem.endsWith(u8, name, ".sx");
                if (!is_sx and !std.mem.endsWith(u8, name, ".md")) continue;
                const md = dir.readFileAlloc(ctx.io, name, gpa, .limited(16 << 20)) catch continue;
                const is_main = std.mem.eql(u8, stripExtension(name), "main");
                // main.* is served at its containing directory's route.
                const route = if (is_main)
                    (if (rel_prefix.len == 0)
                        (if (route_prefix.len == 0) try gpa.dupe(u8, "/") else route_prefix)
                    else
                        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ route_prefix, rel_prefix }))
                else
                    try std.fmt.allocPrint(gpa, "{s}/{s}", .{ route_prefix, stripExtension(rel) });
                const heading = firstHeading(md);
                const label = labelFor(ctx, rel) orelse heading orelse try prettify(gpa, stripExtension(name));
                const doc = try gpa.create(Doc);
                doc.* = .{
                    .rel_path = rel,
                    .route = route,
                    .label = label,
                    .title = heading orelse label,
                    .md = md,
                };
                if (is_main) {
                    // `.sx` beats `.md` when both exist, whatever order the
                    // directory iterates in.
                    if (main_doc == null or (is_sx and !main_is_sx)) {
                        main_doc = doc;
                        main_is_sx = is_sx;
                    }
                    continue;
                }
                try ctx.docs.append(gpa, doc);
                try nodes.append(gpa, .{ .doc = doc });
            },
            else => {},
        }
    }

    sortNodes(nodes.items, ctx.order);
    return .{ .nodes = try nodes.toOwnedSlice(gpa), .main = main_doc };
}

/// Load a single .md/.sx file (a path relative to `dir`) as a synthetic
/// single-page `Site`: one root project whose home is the file, routed at
/// `/`. No nav, no repo link — the quick-preview path for `strike serve <file>`.
pub fn loadFile(io: std.Io, gpa: Allocator, dir: std.Io.Dir, path: []const u8) !Site {
    const doc = try readMainDoc(io, gpa, dir, path, "/");
    const projects = try gpa.alloc(Project, 1);
    projects[0] = .{
        .slug = "",
        .title = doc.title,
        .description = "",
        .repo = "",
        .season = "",
        .time = "",
        .width = "",
        .home = doc,
        .tree = &.{},
        .docs = &.{},
    };
    return .{ .title = doc.title, .repo = "", .season = "", .time = "", .width = "", .projects = projects };
}

/// Read `name` from `dir` into a heap `Doc` served at `route` — for docs
/// picked up outside a project scan (the picker-mode content root's main.*,
/// and `loadFile`'s single file).
fn readMainDoc(io: std.Io, gpa: Allocator, dir: std.Io.Dir, name: []const u8, route: []const u8) !*Doc {
    const md = try dir.readFileAlloc(io, name, gpa, .limited(16 << 20));
    const heading = firstHeading(md);
    const label = heading orelse try prettify(gpa, stripExtension(std.fs.path.basename(name)));
    const doc = try gpa.create(Doc);
    doc.* = .{
        .rel_path = try gpa.dupe(u8, name),
        .route = route,
        .label = label,
        .title = heading orelse label,
        .md = md,
    };
    return doc;
}

// ---- config helpers ---------------------------------------------------------

/// Read+parse a YAML config from `dir`; an empty map on any failure (fail-soft).
pub fn readConfig(io: std.Io, gpa: Allocator, dir: std.Io.Dir, name: []const u8) yaml.Value {
    const src = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch return .{ .map = &.{} };
    return yaml.parse(gpa, src) catch .{ .map = &.{} };
}

/// Resolve a config's `header:` (a dir-relative `.sxh` path) into a `Sheet`.
/// Unset -> empty; unreadable -> a printed warning + empty (fail-soft, like
/// the yaml handling — a bad header never takes the site down).
fn loadHeader(io: std.Io, gpa: Allocator, dir: std.Io.Dir, cfg: yaml.Value) sheet.Sheet {
    const path = cfg.getScalar("header") orelse return .empty;
    return sheet.load(io, gpa, dir, path) catch {
        std.debug.print("strike: warning: header {s} could not be read; ignoring\n", .{path});
        return .empty;
    };
}

pub const Theme = struct { season: []const u8 = "", time: []const u8 = "" };

/// Parse a yaml `theme:` value into season + time (fail-soft, unknown words
/// ignored). Accepted words: a season name, `morning`/`evening`, and the
/// legacy `light`/`dark` (mapped to morning/evening). E.g. "winter evening".
pub fn parseTheme(raw: []const u8) Theme {
    var out: Theme = .{};
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "fall") or std.mem.eql(u8, w, "winter") or
            std.mem.eql(u8, w, "spring") or std.mem.eql(u8, w, "summer"))
        {
            out.season = w;
        } else if (std.mem.eql(u8, w, "morning") or std.mem.eql(u8, w, "light")) {
            out.time = "morning";
        } else if (std.mem.eql(u8, w, "evening") or std.mem.eql(u8, w, "dark")) {
            out.time = "evening";
        }
    }
    return out;
}

fn labelFor(ctx: *ProjCtx, rel: []const u8) ?[]const u8 {
    const labels = ctx.labels orelse return null;
    return labels.getScalar(rel);
}

fn isHidden(ctx: *ProjCtx, rel: []const u8) bool {
    const hidden = ctx.hidden orelse return false;
    for (hidden) |h| switch (h) {
        .scalar => |s| if (std.mem.eql(u8, s, rel)) return true,
        else => {},
    };
    return false;
}

/// Index of `rel` in the project's `order:` list, or null if unlisted.
fn orderIndex(order: ?[]const yaml.Value, rel: []const u8) ?usize {
    const list = order orelse return null;
    for (list, 0..) |v, i| switch (v) {
        .scalar => |s| if (std.mem.eql(u8, s, rel)) return i,
        else => {},
    };
    return null;
}

/// Sort one directory's children: explicit `order:` entries first (by their
/// position), then everything else alphabetically by relative path.
fn sortNodes(nodes: []NavNode, order: ?[]const yaml.Value) void {
    std.mem.sort(NavNode, nodes, order, lessNode);
}

fn lessNode(order: ?[]const yaml.Value, a: NavNode, b: NavNode) bool {
    const ai = orderIndex(order, a.relPath());
    const bi = orderIndex(order, b.relPath());
    if (ai != null and bi != null) return ai.? < bi.?;
    if (ai != null) return true; // listed sorts before unlisted
    if (bi != null) return false;
    return std.mem.lessThan(u8, a.relPath(), b.relPath());
}

// ---- pure string helpers ----------------------------------------------------

/// Strip a trailing `.sx` and/or `.md` (handles the `.sx.md` double extension).
pub fn stripExtension(name: []const u8) []const u8 {
    var s = name;
    if (std.mem.endsWith(u8, s, ".md")) s = s[0 .. s.len - ".md".len];
    if (std.mem.endsWith(u8, s, ".sx")) s = s[0 .. s.len - ".sx".len];
    return s;
}

/// Normalize a site `base:` value into "" (no base) or `/segment[/…]` — one
/// leading slash, no trailing slash — so "docs", "/docs", and "docs/" all
/// mean the same mount point. Caller owns the result when non-empty.
pub fn normalizeBase(gpa: Allocator, raw: []const u8) ![]const u8 {
    var s = std.mem.trim(u8, raw, " ");
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    while (s.len > 0 and s[0] == '/') s = s[1..];
    if (s.len == 0) return "";
    return std.fmt.allocPrint(gpa, "/{s}", .{s});
}

/// Join two project-relative path components with `/` (always forward slash).
fn joinRel(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
    if (a.len == 0) return gpa.dupe(u8, b);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ a, b });
}

/// The text of the document's first ATX heading (`# …`), or null if none.
pub fn firstHeading(md: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != '#') return null; // first non-blank line isn't a heading
        var i: usize = 0;
        while (i < line.len and line[i] == '#') i += 1;
        if (i >= line.len or line[i] != ' ') return null;
        return std.mem.trim(u8, line[i + 1 ..], " \t");
    }
    return null;
}

/// Turn a bare file/folder stem into a human label: drop a leading `NN_`/`NN-`
/// numeric prefix, swap `_`/`-` for spaces, and Title-Case each word.
pub fn prettify(gpa: Allocator, stem: []const u8) Allocator.Error![]const u8 {
    var s = stripExtension(stem);
    // Drop a leading numeric prefix like "01_" / "10-".
    var j: usize = 0;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    if (j > 0 and j < s.len and (s[j] == '_' or s[j] == '-')) s = s[j + 1 ..];

    var out = try gpa.alloc(u8, s.len);
    var at_word_start = true;
    for (s, 0..) |c, i| {
        if (c == '_' or c == '-') {
            out[i] = ' ';
            at_word_start = true;
        } else {
            out[i] = if (at_word_start) std.ascii.toUpper(c) else c;
            at_word_start = false;
        }
    }
    return out;
}

/// Order top-level project slugs by the site `projects:` list, listed first.
fn orderSlugs(slugs: [][]const u8, projects: ?[]const yaml.Value) void {
    std.mem.sort([]const u8, slugs, projects, lessSlug);
}

fn lessSlug(projects: ?[]const yaml.Value, a: []const u8, b: []const u8) bool {
    const ai = slugIndex(projects, a);
    const bi = slugIndex(projects, b);
    if (ai != null and bi != null) return ai.? < bi.?;
    if (ai != null) return true;
    if (bi != null) return false;
    return std.mem.lessThan(u8, a, b);
}

fn slugIndex(projects: ?[]const yaml.Value, slug: []const u8) ?usize {
    const list = projects orelse return null;
    for (list, 0..) |v, i| switch (v) {
        .scalar => |s| if (std.mem.eql(u8, s, slug)) return i,
        else => {},
    };
    return null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "stripExtension handles .md, .sx, and .sx.md" {
    try testing.expectEqualStrings("a", stripExtension("a.md"));
    try testing.expectEqualStrings("a", stripExtension("a.sx"));
    try testing.expectEqualStrings("a", stripExtension("a.sx.md"));
    try testing.expectEqualStrings("topo/algebra", stripExtension("topo/algebra.md"));
}

test "prettify strips numeric prefix and title-cases" {
    const a = try prettify(testing.allocator, "01_probability_statistics.md");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Probability Statistics", a);

    const b = try prettify(testing.allocator, "homeomorphism");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("Homeomorphism", b);

    const c = try prettify(testing.allocator, "state-diagrams.sx");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("State Diagrams", c);
}

test "firstHeading returns leading H1 text or null" {
    try testing.expectEqualStrings("Hello World", firstHeading("# Hello World\n\nbody").?);
    try testing.expectEqualStrings("Deep", firstHeading("\n\n### Deep\n").?);
    try testing.expect(firstHeading("no heading here\n# later") == null);
    try testing.expect(firstHeading("#nospace") == null);
}

test "parseTheme maps legacy and seasonal values" {
    try testing.expectEqualStrings("morning", parseTheme("light").time);
    try testing.expectEqualStrings("evening", parseTheme("dark").time);
    try testing.expectEqualStrings("winter", parseTheme("winter").season);
    const both = parseTheme("fall evening");
    try testing.expectEqualStrings("fall", both.season);
    try testing.expectEqualStrings("evening", both.time);
    const junk = parseTheme("neon ultra");
    try testing.expectEqualStrings("", junk.season);
    try testing.expectEqualStrings("", junk.time);
}

test "orderIndex and slug ordering" {
    const a = yaml.Value{ .scalar = "topo" };
    const b = yaml.Value{ .scalar = "pandas.md" };
    const order = [_]yaml.Value{ a, b };
    try testing.expectEqual(@as(?usize, 0), orderIndex(&order, "topo"));
    try testing.expectEqual(@as(?usize, 1), orderIndex(&order, "pandas.md"));
    try testing.expect(orderIndex(&order, "absent") == null);

    var slugs = [_][]const u8{ "pchem", "data_mining" };
    const projects = [_]yaml.Value{ .{ .scalar = "data_mining" }, .{ .scalar = "pchem" } };
    orderSlugs(&slugs, &projects);
    try testing.expectEqualStrings("data_mining", slugs[0]);
    try testing.expectEqualStrings("pchem", slugs[1]);
}

// `load`/`scan` allocate with a process-/build-lifetime, never-free-piecemeal
// contract (see `load`'s doc comment); an arena over `testing.allocator`
// matches that contract instead of tripping its leak detector.

test "load scans a project folder into a Site" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/hello.md", .data = "# Hello\nbody" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/strike.yaml", .data = "title: Blog\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqual(@as(usize, 1), site.projects.len);
    try testing.expectEqualStrings("Blog", site.projects[0].title);
    try testing.expectEqualStrings("/blog/hello", site.projects[0].docs[0].route);
}

test "load resolves labels, order, and hidden from strike.yaml, and finds home" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "docs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "docs/a.md", .data = "body a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "docs/b.md", .data = "body b" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "docs/secret.md", .data = "shh" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "docs/strike.yaml",
        .data =
        \\home: b.md
        \\labels:
        \\  a.md: First
        \\order:
        \\  - b.md
        \\  - a.md
        \\hidden:
        \\  - secret.md
        \\
        ,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    const p = site.projects[0];
    try testing.expectEqual(@as(usize, 2), p.docs.len); // secret.md is hidden
    try testing.expectEqualStrings("b.md", p.home.?.rel_path);
    try testing.expectEqualStrings("/docs/b", p.tree[0].doc.route); // order: b before a
    try testing.expectEqualStrings("First", p.tree[1].doc.label); // labels: a.md -> First
}

test "load detects the implicit root project from loose docs at the content root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.md", .data = "# Hello\nbody" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqual(@as(usize, 1), site.projects.len);
    try testing.expectEqualStrings("", site.projects[0].slug);
    try testing.expectEqualStrings("/hello", site.projects[0].docs[0].route);
}

test "load supports loose root docs alongside subfolder projects" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.md", .data = "# Hello\nbody" });
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\nbody" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqual(@as(usize, 2), site.projects.len);
    try testing.expectEqualStrings("", site.projects[0].slug); // root project sorts first
    try testing.expectEqualStrings("/hello", site.projects[0].docs[0].route);
    try testing.expectEqualStrings("blog", site.projects[1].slug);
    try testing.expectEqualStrings("/blog/post", site.projects[1].docs[0].route);
}

test "main.md becomes the project home and stays out of nav and docs" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/main.md", .data = "# Welcome\nintro" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\nbody" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    const p = site.projects[0];
    try testing.expectEqual(@as(usize, 1), p.docs.len); // main.md is not a routed doc
    try testing.expectEqual(@as(usize, 1), p.tree.len); // and not a nav node
    try testing.expectEqualStrings("main.md", p.home.?.rel_path);
    try testing.expectEqualStrings("/blog", p.home.?.route); // the folder's own route
}

test "yaml home: beats main.md" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/main.md", .data = "# Welcome\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/strike.yaml", .data = "home: post.md\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqualStrings("post.md", site.projects[0].home.?.rel_path);
}

test "subfolder main.md gives the folder a page at the folder's route" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blog/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/sub/main.md", .data = "# Sub\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/sub/a.md", .data = "# A\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    const p = site.projects[0];
    try testing.expectEqual(@as(usize, 1), p.docs.len); // just a.md
    const folder = p.tree[0].folder;
    try testing.expectEqualStrings("/blog/sub", folder.main.?.route);
    try testing.expectEqual(@as(usize, 1), folder.children.len);
    try testing.expect(p.home == null); // project root has no main.*
}

test "root main.md alone keeps picker mode and sets Site.main" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.md", .data = "# Intro\n" });
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqual(@as(usize, 1), site.projects.len); // no implicit root project
    try testing.expectEqualStrings("blog", site.projects[0].slug);
    try testing.expectEqualStrings("Intro", site.main.?.title);
}

test "root main.md with loose docs joins the root project as its home" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.md", .data = "# Front\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.md", .data = "# Hello\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expect(site.main == null);
    const p = site.projects[0];
    try testing.expectEqualStrings("", p.slug);
    try testing.expectEqualStrings("/", p.home.?.route);
    try testing.expectEqual(@as(usize, 1), p.docs.len); // hello.md only
}

test "header: loads .sxh sheets, project layered over site" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "strike.yaml", .data = "header: site.sxh\n" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "site.sxh",
        .data = ":color brand #111111\n:color soft #9aa4b2\n",
    });
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/strike.yaml", .data = "header: theme.sxh\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/theme.sxh", .data = ":color brand #222222\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    // site sheet holds the site header's aliases
    try testing.expectEqualStrings("#111111", site.sheet.lookup("brand").?);
    // the project's own header wins for redefined names, site fills the rest
    const blog = site.projects[0];
    try testing.expectEqualStrings("#222222", blog.sheet.lookup("brand").?);
    try testing.expectEqualStrings("#9aa4b2", blog.sheet.lookup("soft").?);
    // the .sxh files never become documents
    try testing.expectEqual(@as(usize, 1), blog.docs.len);
}

test "a missing header degrades to an empty sheet" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/strike.yaml", .data = "header: nope.sxh\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);
    try testing.expect(site.projects[0].sheet.lookup("brand") == null);
}

test "main.sx beats main.md" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blog");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/main.md", .data = "# MD\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/main.sx", .data = "# SX\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqualStrings("main.sx", site.projects[0].home.?.rel_path);
}

test "normalizeBase accepts docs, /docs, and docs/ alike" {
    try testing.expectEqualStrings("", try normalizeBase(testing.allocator, ""));
    try testing.expectEqualStrings("", try normalizeBase(testing.allocator, "/"));
    const cases = [_][]const u8{ "docs", "/docs", "docs/", "/docs/" };
    for (cases) |raw| {
        const b = try normalizeBase(testing.allocator, raw);
        defer testing.allocator.free(b);
        try testing.expectEqualStrings("/docs", b);
    }
    const multi = try normalizeBase(testing.allocator, "/a/b/");
    defer testing.allocator.free(multi);
    try testing.expectEqualStrings("/a/b", multi);
}

test "site base: prefixes every route" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "strike.yaml", .data = "base: /docs\n" });
    try tmp.dir.createDirPath(testing.io, "blog/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/post.md", .data = "# Post\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/main.md", .data = "# Home\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/sub/a.md", .data = "# A\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blog/sub/main.md", .data = "# Sub\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqualStrings("/docs", site.base);
    const p = site.projects[0];
    try testing.expectEqualStrings("/docs", p.base);
    // the flat docs list is append-ordered (directory iteration), so search it
    var saw_post = false;
    for (p.docs) |d| {
        if (std.mem.eql(u8, d.rel_path, "post.md")) {
            try testing.expectEqualStrings("/docs/blog/post", d.route);
            saw_post = true;
        }
    }
    try testing.expect(saw_post);
    try testing.expectEqualStrings("/docs/blog", p.home.?.route); // project-root main.md
    try testing.expectEqualStrings("/docs/blog/sub", p.tree[1].folder.main.?.route); // folder page
}

test "site base: prefixes root-project routes too" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "strike.yaml", .data = "base: /docs\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.md", .data = "# Hello\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.md", .data = "# Front\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    const p = site.projects[0];
    try testing.expectEqualStrings("/docs/hello", p.docs[0].route);
    try testing.expectEqualStrings("/docs", p.home.?.route); // root main.md sits at the base
}

test "loadFile builds a synthetic single-page Site routed at /" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "# My Notes\nbody" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try loadFile(testing.io, arena.allocator(), tmp.dir, "notes.md");

    try testing.expectEqualStrings("My Notes", site.title);
    try testing.expectEqualStrings("", site.repo); // no repo link in the shell
    const p = site.projects[0];
    try testing.expectEqualStrings("/", p.home.?.route);
    try testing.expectEqual(@as(usize, 0), p.docs.len);
    try testing.expectEqual(@as(usize, 0), p.tree.len);
}

test "a directory with no doc files and no subfolders yields an empty Site" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const site = try load(testing.io, arena.allocator(), tmp.dir);

    try testing.expectEqual(@as(usize, 0), site.projects.len);
}
