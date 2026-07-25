//! The HTML backend: walks a `strikedown.Doc` tree and emits an HTML fragment.
//!
//! All HTML emission for document *content* lives here (page chrome lives in
//! `shell.zig`; site-structure rendering in `site.zig`). `render` is the
//! parse+emit convenience every caller uses; `emit` is the tree walk on its
//! own, for callers that already hold a `Doc`. A future PDF backend is a
//! sibling file (`render_pdf.zig`) walking the same tree — keep everything
//! HTML-specific here and nothing HTML-specific in `strikedown.zig`.
//!
//! Output notes:
//!   - math is delimiter-rewritten only: inline TeX -> `\(…\)`, display ->
//!     `\[…\]`, HTML-escaped; client-side MathJax does the typesetting (the
//!     loader is in `shell.zig`)
//!   - a fence's language lands as `class="language-…"`
//!   - a group's attributes (`columns`, `width_pct`, `centered`, `text_color`)
//!     land as inline `style` declarations on its `sx-group` wrapper; a
//!     `[text].color(role)` span becomes an inline-styled `sx-color` span.
//!     Color roles emit as `var(--<role>)` references, resolved by the active
//!     theme in `shell.zig` — links/blockquotes/code keep their own
//!     element-selector colors inside colored regions (deliberate; see
//!     `docs/design/006-color.md`)
//!
//! The end-to-end `expectRender` tests at the bottom are the renderer's
//! specification — they predate the parse/emit split and must keep passing
//! unchanged.

const std = @import("std");
const strikedown = @import("strikedown.zig");
const sheet = @import("sheet.zig");
const html = @import("html.zig");
const escapeInto = html.escapeInto;
const escapeAttrInto = html.escapeAttrInto;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Per-render settings — the extension point for future options. `sheet` is
/// the base typography sheet (a site/project `.sxh` header) — inert while
/// the directive namespace is reserved, kept so the plumbing stays wired.
pub const Options = struct {
    sheet: sheet.Sheet = .empty,
    /// Route of the rendered document's containing directory ("" at the site
    /// root, "/data_mining/topo" for a nested doc — `project.Doc.route_dir`).
    /// Doc-relative link targets (`[spec](design/spec.md)`, `../notes.sx`,
    /// with an optional `#fragment`) resolve against it into extensionless
    /// routes; absolute URLs, site-absolute paths, and non-doc targets pass
    /// through untouched.
    link_base: []const u8 = "",
};

/// Render strikedown/markdown source to an HTML fragment (no surrounding
/// `<html>`/`<body>`). The parse tree lives in an internal arena freed before
/// returning; the caller owns the returned slice and frees it with `gpa`.
pub fn render(gpa: Allocator, src: []const u8, opts: Options) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try strikedown.parse(arena_state.allocator(), src, opts.sheet);
    for (doc.warnings) |warning| std.debug.print("strike: warning: {s}\n", .{warning});
    return emit(gpa, doc, opts);
}

/// Emit an already-parsed `Doc` as an HTML fragment. Caller owns the result.
pub fn emit(gpa: Allocator, doc: strikedown.Doc, opts: Options) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (doc.blocks) |block| try emitBlock(&out.writer, block, opts.link_base);
    return out.toOwnedSlice();
}

/// The gap between grid sections. A future gap() command would replace this
/// constant with an `Attrs` field read below.
const grid_gap = "1.5rem";

/// Emit ` style="…"` (leading space included) from a block's attrs — or
/// nothing at all when every styling attr is unset (structural attrs like
/// `collapse` shape elements instead and never land here). The single owner
/// of CSS declaration order: grid, width, center, color, indent (the order
/// the render tests lock; extend at the end). `columns` only ever appears on
/// group blocks — the parser sets attrs nowhere else, and grid arranges
/// sections, which only groups have — so the grid CSS needs no non-group
/// guard.
fn writeStyleAttr(w: *Writer, attrs: strikedown.Attrs) Writer.Error!void {
    if (!attrs.anyStyle()) return;
    try w.writeAll(" style=\"");
    var sep = false;
    if (attrs.columns) |n| {
        try w.print("display:grid;grid-template-columns:repeat({d},minmax(0,1fr));gap:" ++ grid_gap, .{n});
        sep = true;
    }
    if (attrs.width_pct) |pct| {
        if (sep) try w.writeByte(';');
        try w.print("width:{d}%;margin-inline:auto", .{pct});
        sep = true;
    }
    if (attrs.centered) {
        if (sep) try w.writeByte(';');
        try w.writeAll("text-align:center");
        sep = true;
    }
    if (attrs.text_color) |role| {
        if (sep) try w.writeByte(';');
        try w.print("color:var(--{t})", .{role});
        sep = true;
    }
    if (attrs.indent != 0) {
        if (sep) try w.writeByte(';');
        try w.print("text-indent:{d}rem", .{attrs.indent * 2});
    }
    try w.writeByte('"');
}

fn emitBlock(w: *Writer, block: strikedown.Block, link_base: []const u8) Writer.Error!void {
    switch (block.kind) {
        .heading => |h| {
            try w.print("<h{d} id=\"", .{h.level});
            try escapeAttrInto(w, h.id);
            try w.writeByte('"');
            try writeStyleAttr(w, block.attrs);
            try w.writeByte('>');
            try emitInlines(w, h.inlines, link_base);
            try w.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |inls| {
            try w.writeAll("<p");
            try writeStyleAttr(w, block.attrs);
            try w.writeByte('>');
            try emitInlines(w, inls, link_base);
            try w.writeAll("</p>\n");
        },
        .quote => |q| {
            try w.writeAll("<blockquote");
            if (q.alert) |a| try w.print(" class=\"sx-alert sx-alert-{t}\"", .{a});
            try writeStyleAttr(w, block.attrs);
            try w.writeAll(">\n");
            if (q.alert) |a| {
                try w.writeAll("<p class=\"sx-alert-title\">");
                try w.writeAll(alertLabel(a));
                try w.writeAll("</p>\n");
            }
            for (q.paras) |inls| {
                try w.writeAll("<p>");
                try emitInlines(w, inls, link_base);
                try w.writeAll("</p>\n");
            }
            try w.writeAll("</blockquote>\n");
        },
        .list => |list| try emitList(w, list, block.attrs, link_base),
        .code => |code| {
            try w.writeAll("<pre");
            try writeStyleAttr(w, block.attrs);
            if (code.lang.len > 0) {
                try w.writeAll("><code class=\"language-");
                try escapeAttrInto(w, code.lang);
                try w.writeAll("\">");
            } else {
                try w.writeAll("><code>");
            }
            try escapeInto(w, code.text);
            try w.writeAll("</code></pre>\n");
        },
        .table => |table| {
            try w.writeAll("<table");
            try writeStyleAttr(w, block.attrs);
            try w.writeAll(">\n<thead>\n<tr>");
            for (table.header, 0..) |cell, ci| {
                try writeCell(w, "th", strikedown.alignAt(table.aligns, ci), cell, link_base);
            }
            try w.writeAll("</tr>\n</thead>\n<tbody>\n");
            for (table.rows) |row| {
                try w.writeAll("<tr>");
                for (row, 0..) |cell, ci| {
                    try writeCell(w, "td", strikedown.alignAt(table.aligns, ci), cell, link_base);
                }
                try w.writeAll("</tr>\n");
            }
            try w.writeAll("</tbody>\n</table>\n");
        },
        .math => |tex| {
            // Display math emits raw `\[…\]` for MathJax with no wrapper
            // element, so there is nothing to hang a style attribute on; a
            // future styled-math decision means choosing a wrapper first.
            try w.writeAll("\\[");
            try escapeInto(w, tex);
            try w.writeAll("\\]\n");
        },
        .rule => {
            try w.writeAll("<hr");
            try writeStyleAttr(w, block.attrs);
            try w.writeAll("/>\n");
        },
        .group => |g| {
            if (block.attrs.collapse) |c| return emitCollapse(w, g, c, block.attrs, link_base);
            // Styles are inline (not shell CSS) so fragments and static
            // exports are self-contained; the classes are hooks for future
            // reader styling.
            try w.writeAll("<div class=\"sx-group\"");
            try writeStyleAttr(w, block.attrs);
            try w.writeAll(">\n");
            for (g.sections) |section| {
                try w.writeAll("<div class=\"sx-group-sec\">\n");
                for (section) |b| try emitBlock(w, b, link_base);
                try w.writeAll("</div>\n");
            }
            try w.writeAll("</div>\n");
        },
    }
}

/// A collapsible group (007-collapse): a disclosure element whose summary is
/// the group's *leader* — its first block, when it has at least two — and
/// whose remaining content sits in a body wrapper. The group's styling attrs
/// go on the body, never on the disclosure element itself (a grid style
/// there would make the summary a grid item); `collapse` reaches the
/// emitter only as element shape. A group with one block or none gets the
/// empty-bar summary and folds everything.
fn emitCollapse(w: *Writer, g: strikedown.Group, c: strikedown.Collapse, attrs: strikedown.Attrs, link_base: []const u8) Writer.Error!void {
    var total: usize = 0;
    for (g.sections) |section| total += section.len;
    const has_leader = total >= 2 and g.sections[0].len > 0;
    try w.writeAll("<details class=\"sx-group sx-collapse\"");
    if (c == .open) try w.writeAll(" open");
    try w.writeAll(">\n");
    if (has_leader) {
        try w.writeAll("<summary>");
        try emitBlock(w, g.sections[0][0], link_base);
        try w.writeAll("</summary>\n");
    } else {
        try w.writeAll("<summary class=\"sx-collapse-bar\"></summary>\n");
    }
    try w.writeAll("<div class=\"sx-collapse-body\"");
    try writeStyleAttr(w, attrs);
    try w.writeAll(">\n");
    for (g.sections, 0..) |section, si| {
        try w.writeAll("<div class=\"sx-group-sec\">\n");
        const body = if (has_leader and si == 0) section[1..] else section;
        for (body) |b| try emitBlock(w, b, link_base);
        try w.writeAll("</div>\n");
    }
    try w.writeAll("</div>\n</details>\n");
}

/// The alert's rendered title text — the type name, capitalized.
fn alertLabel(a: strikedown.Alert) []const u8 {
    return switch (a) {
        .note => "Note",
        .tip => "Tip",
        .important => "Important",
        .warning => "Warning",
        .caution => "Caution",
        .todo => "Todo",
        .example => "Example",
        .question => "Question",
    };
}

/// `attrs` styles the outer `<ul>`/`<ol>` only; nested lists (`Item.Tail`)
/// aren't `Block`s and can't carry attrs — the recursion passes `.{}`.
fn emitList(w: *Writer, list: strikedown.List, attrs: strikedown.Attrs, link_base: []const u8) Writer.Error!void {
    try w.writeAll(if (list.ordered) "<ol" else "<ul");
    // Raw lists render markerless; the class is the hook, reader CSS
    // removes bullets and marker indentation (008-raw-lists).
    if (list.plain) try w.writeAll(" class=\"sx-plain\"");
    try writeStyleAttr(w, attrs);
    if (list.ordered and list.start != 1) {
        try w.print(" start=\"{d}\"", .{list.start});
    }
    try w.writeAll(">\n");
    for (list.items) |item| {
        try w.writeAll("<li>");
        if (item.task) |checked| {
            try w.writeAll(if (checked)
                "<input type=\"checkbox\" disabled checked> "
            else
                "<input type=\"checkbox\" disabled> ");
        }
        try emitInlines(w, item.text, link_base);
        for (item.tail) |tail| switch (tail) {
            .line => |inls| {
                try w.writeByte(' ');
                try emitInlines(w, inls, link_base);
            },
            .list => |sub| {
                try w.writeByte('\n');
                try emitList(w, sub, .{}, link_base);
            },
        };
        try w.writeAll("</li>\n");
    }
    try w.writeAll(if (list.ordered) "</ol>\n" else "</ul>\n");
}

/// One `<th>`/`<td>` with its alignment style and inline content.
fn writeCell(w: *Writer, tag: []const u8, al: strikedown.Align, inls: []const strikedown.Inline, link_base: []const u8) Writer.Error!void {
    try w.writeByte('<');
    try w.writeAll(tag);
    switch (al) {
        .none => {},
        .left => try w.writeAll(" style=\"text-align:left\""),
        .center => try w.writeAll(" style=\"text-align:center\""),
        .right => try w.writeAll(" style=\"text-align:right\""),
    }
    try w.writeByte('>');
    try emitInlines(w, inls, link_base);
    try w.writeAll("</");
    try w.writeAll(tag);
    try w.writeByte('>');
}

fn emitInlines(w: *Writer, inls: []const strikedown.Inline, link_base: []const u8) Writer.Error!void {
    for (inls) |inl| switch (inl) {
        .text => |s| try escapeInto(w, s),
        .code => |s| {
            try w.writeAll("<code>");
            try escapeInto(w, s);
            try w.writeAll("</code>");
        },
        .math => |s| {
            try w.writeAll("\\(");
            try escapeInto(w, s);
            try w.writeAll("\\)");
        },
        .image => |img| {
            try w.writeAll("<img src=\"");
            try escapeAttrInto(w, img.src);
            try w.writeAll("\" alt=\"");
            try escapeAttrInto(w, img.alt);
            try w.writeAll("\">");
        },
        .link => |l| {
            try w.writeAll("<a href=\"");
            if (docLinkPath(l.url)) |path| {
                try writeDocHref(w, link_base, path, l.url[path.len..]);
            } else {
                try escapeAttrInto(w, l.url);
            }
            try w.writeAll("\">");
            try emitInlines(w, l.children, link_base);
            try w.writeAll("</a>");
        },
        .autolink => |url| {
            try w.writeAll("<a href=\"");
            try escapeAttrInto(w, url);
            try w.writeAll("\">");
            try escapeInto(w, url);
            try w.writeAll("</a>");
        },
        .color_span => |span| {
            try w.print("<span class=\"sx-color\" style=\"color:var(--{t})\">", .{span.color});
            try emitInlines(w, span.children, link_base);
            try w.writeAll("</span>");
        },
        .strong => |c| {
            try w.writeAll("<strong>");
            try emitInlines(w, c, link_base);
            try w.writeAll("</strong>");
        },
        .em => |c| {
            try w.writeAll("<em>");
            try emitInlines(w, c, link_base);
            try w.writeAll("</em>");
        },
        .strong_em => |c| {
            try w.writeAll("<strong><em>");
            try emitInlines(w, c, link_base);
            try w.writeAll("</em></strong>");
        },
        .strike => |c| {
            try w.writeAll("<del>");
            try emitInlines(w, c, link_base);
            try w.writeAll("</del>");
        },
    };
}

// ---- tests ------------------------------------------------------------------
// The renderer's end-to-end specification, unchanged across the parse/emit
// split (it used to live in markdown.zig's single-pass renderer).

/// The path part of a doc-relative link target (`design/spec.md#anchor` ->
/// `design/spec.md`), or null when the target isn't one. Only relative paths
/// ending in `.md`/`.sx` activate the rewrite — absolute URLs, `mailto:`,
/// site-absolute paths, bare fragments, and everything else pass through
/// verbatim, so plain-markdown documents render exactly as before.
fn docLinkPath(url: []const u8) ?[]const u8 {
    if (url.len == 0 or url[0] == '/' or url[0] == '#') return null;
    const end = std.mem.indexOfAny(u8, url, "#?") orelse url.len;
    const path = url[0..end];
    if (std.mem.indexOfScalar(u8, path, ':') != null) return null; // a scheme (https:, mailto:, ...)
    if (!std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".sx")) return null;
    return path;
}

/// Emit the route a doc-relative link resolves to: leading `./`s drop, each
/// leading `../` pops a segment off `base` (clamped at the site root), the
/// `.md`/`.sx` extension drops, and a trailing `main` segment collapses to
/// its folder's own route (main.* docs are served there). `suffix` is the
/// target's `#fragment`/`?query` tail, appended untouched.
fn writeDocHref(w: *Writer, base: []const u8, path: []const u8, suffix: []const u8) Writer.Error!void {
    var b = base;
    var p = path;
    while (true) {
        if (std.mem.startsWith(u8, p, "./")) {
            p = p[2..];
        } else if (std.mem.startsWith(u8, p, "../")) {
            p = p[3..];
            b = if (std.mem.lastIndexOfScalar(u8, b, '/')) |i| b[0..i] else "";
        } else break;
    }
    var stem = stripDocExt(p);
    if (std.mem.eql(u8, stem, "main")) {
        stem = "";
    } else if (std.mem.endsWith(u8, stem, "/main")) {
        stem = stem[0 .. stem.len - "/main".len];
    }
    if (stem.len == 0) {
        if (b.len == 0) try w.writeByte('/') else try escapeAttrInto(w, b);
    } else {
        try escapeAttrInto(w, b);
        try w.writeByte('/');
        try escapeAttrInto(w, stem);
    }
    try escapeAttrInto(w, suffix);
}

/// Strip a trailing `.sx` and/or `.md` (the `.sx.md` double extension too) —
/// mirrors route building in `project.zig`'s `stripExtension`.
fn stripDocExt(path: []const u8) []const u8 {
    var s = path;
    if (std.mem.endsWith(u8, s, ".md")) s = s[0 .. s.len - ".md".len];
    if (std.mem.endsWith(u8, s, ".sx")) s = s[0 .. s.len - ".sx".len];
    return s;
}

fn expectRender(expected: []const u8, md: []const u8) !void {
    const got = try render(std.testing.allocator, md, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

fn expectRenderAt(link_base: []const u8, expected: []const u8, md: []const u8) !void {
    const got = try render(std.testing.allocator, md, .{ .link_base = link_base });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "headings" {
    try expectRender("<h1 id=\"title\">Title</h1>\n", "# Title");
    try expectRender("<h3 id=\"sub\">Sub</h3>\n", "### Sub");
    // seven hashes is not a heading -> paragraph
    try expectRender("<p>####### nope</p>\n", "####### nope");
}

test "heading anchor ids" {
    try expectRender("<h2 id=\"my-heading\">My Heading!</h2>\n", "## My Heading!");
    // repeated headings dedupe with -2, -3, …
    try expectRender(
        "<h1 id=\"a\">A</h1>\n<h1 id=\"a-2\">A</h1>\n",
        "# A\n\n# A",
    );
    // slug comes from the raw text; inline markup collapses to dashes
    try expectRender(
        "<h2 id=\"use-code-now\">Use <code>code</code> now</h2>\n",
        "## Use `code` now",
    );
    // all-punctuation heading falls back to "section"
    try expectRender("<h1 id=\"section\">???</h1>\n", "# ???");
}

test "paragraph joins soft-wrapped lines" {
    try expectRender("<p>one two</p>\n", "one\ntwo");
    try expectRender("<p>a</p>\n<p>b</p>\n", "a\n\nb");
}

test "inline bold, italic and code" {
    try expectRender("<p><strong>b</strong> and <em>i</em></p>\n", "**b** and *i*");
    try expectRender("<p>use <code>x &lt; y</code></p>\n", "use `x < y`");
}

test "triple-star renders nested bold+italic, not a leftover asterisk" {
    try expectRender("<p><strong><em>both</em></strong></p>\n", "***both***");
    try expectRender("<p>a <strong><em>b</em></strong> c</p>\n", "a ***b*** c");
}

test "links" {
    try expectRender(
        "<p><a href=\"https://z.dev\">Zig</a></p>\n",
        "[Zig](https://z.dev)",
    );
}

test "doc-relative .md/.sx links resolve to routes" {
    // from the site root: extension drops, subfolder path survives
    try expectRender(
        "<p><a href=\"/design/001-groups\">groups</a></p>\n",
        "[groups](design/001-groups.md)",
    );
    try expectRender("<p><a href=\"/notes\">n</a></p>\n", "[n](notes.sx)");
    // from a nested doc: sibling and `../` targets resolve against link_base
    try expectRenderAt(
        "/design",
        "<p><a href=\"/design/001-groups\">g</a></p>\n",
        "[g](001-groups.md)",
    );
    try expectRenderAt(
        "/design",
        "<p><a href=\"/STRIKEDOWN\">spec</a></p>\n",
        "[spec](../STRIKEDOWN.md)",
    );
    // `../` clamps at the site root; `./` is dropped
    try expectRenderAt("", "<p><a href=\"/a\">a</a></p>\n", "[a](../../a.md)");
    try expectRenderAt("/p", "<p><a href=\"/p/a\">a</a></p>\n", "[a](./a.md)");
    // a fragment survives the rewrite
    try expectRender(
        "<p><a href=\"/spec#anchors\">s</a></p>\n",
        "[s](spec.md#anchors)",
    );
    // main.* links land on the containing folder's own route
    try expectRenderAt("/p", "<p><a href=\"/p/sub\">s</a></p>\n", "[s](sub/main.md)");
    try expectRenderAt("/p", "<p><a href=\"/p\">home</a></p>\n", "[home](main.md)");
    try expectRenderAt("", "<p><a href=\"/\">home</a></p>\n", "[home](main.md)");
}

test "non-doc link targets pass through untouched" {
    try expectRenderAt("/p", "<p><a href=\"https://z.dev/x.md\">x</a></p>\n", "[x](https://z.dev/x.md)");
    try expectRenderAt("/p", "<p><a href=\"/abs/x.md\">x</a></p>\n", "[x](/abs/x.md)");
    try expectRenderAt("/p", "<p><a href=\"#frag\">f</a></p>\n", "[f](#frag)");
    try expectRenderAt("/p", "<p><a href=\"img/pic.png\">p</a></p>\n", "[p](img/pic.png)");
    try expectRenderAt("/p", "<p><a href=\"mailto:a@b.md\">m</a></p>\n", "[m](mailto:a@b.md)");
}

test "unordered and ordered lists" {
    try expectRender("<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", "- a\n- b");
    try expectRender("<ol>\n<li>x</li>\n<li>y</li>\n</ol>\n", "1. x\n2. y");
    // `*` and `+` bullets still work
    try expectRender("<ul>\n<li>a</li>\n</ul>\n", "* a");
    try expectRender("<ul>\n<li>a</li>\n</ul>\n", "+ a");
}

test "nested unordered lists" {
    try expectRender(
        "<ul>\n<li>a\n<ul>\n<li>a1</li>\n</ul>\n</li>\n<li>b</li>\n</ul>\n",
        "- a\n  - a1\n- b",
    );
}

test "ordered list nested in unordered" {
    try expectRender(
        "<ul>\n<li>a\n<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n</li>\n</ul>\n",
        "- a\n  1. one\n  2. two",
    );
}

test "three levels of nesting" {
    try expectRender(
        "<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n",
        "- a\n  - b\n    - c",
    );
}

test "task lists" {
    try expectRender(
        "<ul>\n<li><input type=\"checkbox\" disabled checked> done</li>\n" ++
            "<li><input type=\"checkbox\" disabled> todo</li>\n</ul>\n",
        "- [x] done\n- [ ] todo",
    );
}

test "raw list: markerless ul with the sx-plain hook" {
    try expectRender(
        "<ul class=\"sx-plain\">\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ul>\n",
        ". one\n. two\n. three",
    );
}

test "raw list: mixed markers split; task boxes still work" {
    try expectRender(
        "<ul>\n<li>bulleted</li>\n</ul>\n<ul class=\"sx-plain\">\n<li>raw</li>\n</ul>\n",
        "- bulleted\n. raw",
    );
    try expectRender(
        "<ul class=\"sx-plain\">\n<li><input type=\"checkbox\" disabled> todo</li>\n</ul>\n",
        ". [ ] todo",
    );
}

test "list item continuation lines join the item" {
    try expectRender("<ul>\n<li>a b</li>\n</ul>\n", "- a\n  b");
}

test "unindented line lazily continues the list item" {
    try expectRender("<ul>\n<li>a text</li>\n</ul>\n", "- a\ntext");
}

test "blank lines between items keep one list" {
    try expectRender(
        "<ol>\n<li>x</li>\n<li>y</li>\n<li>z</li>\n</ol>\n",
        "1. x\n2. y\n\n3. z",
    );
}

test "ordered list starts at the first written number" {
    try expectRender("<ol start=\"3\">\n<li>x</li>\n<li>y</li>\n</ol>\n", "3. x\n4. y");
}

test "block forms still terminate a list" {
    try expectRender("<ul>\n<li>a</li>\n</ul>\n<h1 id=\"h\">h</h1>\n", "- a\n# h");
    try expectRender("<ul>\n<li>a</li>\n</ul>\n<hr/>\n", "- a\n\n---");
}

test "sibling list of the other kind splits" {
    try expectRender(
        "<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>one</li>\n</ol>\n",
        "- a\n1. one",
    );
}

test "fenced code block escapes and skips inline parsing" {
    try expectRender(
        "<pre><code>let x = &amp;y;\n**not bold**\n</code></pre>\n",
        "```\nlet x = &y;\n**not bold**\n```",
    );
}

test "blockquote" {
    try expectRender("<blockquote>\n<p>quoted</p>\n</blockquote>\n", "> quoted");
}

test "horizontal rule vs list item" {
    try expectRender("<hr/>\n", "---");
    try expectRender("<ul>\n<li>x</li>\n</ul>\n", "- x");
}

test "html is escaped in paragraphs" {
    try expectRender("<p>a &amp; b &lt;tag&gt;</p>\n", "a & b <tag>");
}

test "inline math passes through as \\( \\)" {
    try expectRender("<p>see \\(a^2\\)</p>\n", "see $a^2$");
}

test "display math passes through as \\[ \\]" {
    try expectRender("\\[E=mc^2\\]\n", "$$E=mc^2$$");
}

test "math is html-escaped but not markdown-parsed" {
    try expectRender("<p>\\(a &lt; b\\)</p>\n", "$a < b$");
    try expectRender("<p>\\(a*b*c\\)</p>\n", "$a*b*c$");
}

test "backslash escapes make punctuation literal" {
    try expectRender("<p>*not em*</p>\n", "\\*not em\\*");
    try expectRender("<p>`x`</p>\n", "\\`x\\`");
    try expectRender("<p>$5 and $6</p>\n", "\\$5 and \\$6");
    // a backslash before a non-escapable char (or at end of line) is literal
    try expectRender("<p>a\\b \\</p>\n", "a\\b \\");
}

test "images" {
    try expectRender(
        "<p><img src=\"cat.png\" alt=\"a cat\"></p>\n",
        "![a cat](cat.png)",
    );
    // alt and src are attribute-escaped, alt is not inline-parsed
    try expectRender(
        "<p><img src=\"a&quot;.png\" alt=\"**x**\"></p>\n",
        "![**x**](a\".png)",
    );
    // a bare `!` stays literal
    try expectRender("<p>hey!</p>\n", "hey!");
}

test "angle autolinks" {
    try expectRender(
        "<p>see <a href=\"https://z.dev\">https://z.dev</a></p>\n",
        "see <https://z.dev>",
    );
    // non-URL angle content is still escaped, not linked
    try expectRender("<p>&lt;tag&gt;</p>\n", "<tag>");
}

test "bare URLs" {
    try expectRender(
        "<p>go to <a href=\"https://z.dev/x\">https://z.dev/x</a>.</p>\n",
        "go to https://z.dev/x.",
    );
    try expectRender(
        "<p>(<a href=\"http://a.io\">http://a.io</a>)</p>\n",
        "(http://a.io)",
    );
    // inside a code span, untouched
    try expectRender("<p><code>https://z.dev</code></p>\n", "`https://z.dev`");
    // a bare scheme with no body is prose
    try expectRender("<p>https:// is a scheme</p>\n", "https:// is a scheme");
}

test "strikethrough" {
    try expectRender("<p><del>gone</del></p>\n", "~~gone~~");
    try expectRender("<p><del>a <strong>b</strong></del></p>\n", "~~a **b**~~");
    try expectRender("<p>~~ not closed</p>\n", "~~ not closed");
}

test "pipe tables" {
    try expectRender(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        "| a | b |\n| --- | --- |\n| 1 | 2 |",
    );
    // boundary pipes are optional
    try expectRender(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        "a | b\n--- | ---\n1 | 2",
    );
}

test "table alignment" {
    try expectRender(
        "<table>\n<thead>\n<tr><th style=\"text-align:left\">l</th>" ++
            "<th style=\"text-align:center\">c</th>" ++
            "<th style=\"text-align:right\">r</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td style=\"text-align:left\">1</td>" ++
            "<td style=\"text-align:center\">2</td>" ++
            "<td style=\"text-align:right\">3</td></tr>\n</tbody>\n</table>\n",
        "| l | c | r |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |",
    );
}

test "table rows pad and truncate to the header width" {
    try expectRender(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>1</td><td></td></tr>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |",
    );
}

test "inline markup inside table cells" {
    try expectRender(
        "<table>\n<thead>\n<tr><th><strong>a</strong></th><th><code>c</code></th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>\\(x\\)</td><td><em>i</em></td></tr>\n</tbody>\n</table>\n",
        "| **a** | `c` |\n|---|---|\n| $x$ | *i* |",
    );
}

test "escaped pipe stays inside its cell" {
    try expectRender(
        "<table>\n<thead>\n<tr><th>a|b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>x</td></tr>\n</tbody>\n</table>\n",
        "| a\\|b |\n|---|\n| x |",
    );
}

test "table interrupts a paragraph" {
    try expectRender(
        "<p>intro</p>\n<table>\n<thead>\n<tr><th>a</th></tr>\n</thead>\n<tbody>\n</tbody>\n</table>\n",
        "intro\n| a |\n|---|",
    );
}

test "pipe row without a separator stays a paragraph" {
    try expectRender("<p>| a | b |</p>\n", "| a | b |");
}

test "reserved `:` directive lines are prose" {
    // the `:` namespace is reserved but recognizes nothing — every `:` line,
    // including the retired `:color`, renders literally
    try expectRender("<p>:color brand #7c3aed</p>\n", ":color brand #7c3aed");
    try expectRender("<p>:margin 2rem</p>\n", ":margin 2rem");
    // the retired `(name)` prefix is likewise plain prose
    try expectRender("<p>(note)# not a heading</p>\n", "(note)# not a heading");
}

test "alert: canonical multi-line form" {
    try expectRender(
        "<blockquote class=\"sx-alert sx-alert-note\">\n<p class=\"sx-alert-title\">Note</p>\n<p>body line one body line two</p>\n</blockquote>\n",
        "> [!NOTE]\n> body line one\n> body line two",
    );
}

test "alert: same-line text, case-insensitive type" {
    try expectRender(
        "<blockquote class=\"sx-alert sx-alert-warning\">\n<p class=\"sx-alert-title\">Warning</p>\n<p>one-liner body</p>\n</blockquote>\n",
        "> [!warning] one-liner body",
    );
}

test "alert: unknown type degrades to a plain quote" {
    try expectRender(
        "<blockquote>\n<p>[!IDEA] hm</p>\n</blockquote>\n",
        "> [!IDEA] hm",
    );
}

test "quote paragraphs: merge, bare-> split, lazy continuation" {
    try expectRender("<blockquote>\n<p>a b</p>\n</blockquote>\n", "> a\n> b");
    try expectRender(
        "<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n",
        "> a\n>\n> b",
    );
    try expectRender(
        "<blockquote>\n<p>a b</p>\n</blockquote>\n<p>after</p>\n",
        "> a\nb\n\nafter",
    );
}

test "group directive: two lists render side by side (main.sx)" {
    try expectRender(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<ol>\n<li>c</li>\n<li>d</li>\n</ol>\n</div>\n" ++
            "</div>\n",
        "// two_lists grid(2)\n\n1. a\n2. b\n\n// --\n\n1. c\n2. d\n\n// end two_lists",
    );
}

test "group directive: nameless group without commands beyond grid" {
    try expectRender(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n" ++
            "</div>\n",
        "// grid(2)\n\na\n\n// --\n\nb",
    );
}

test "group directive: a group with no commands is a plain container" {
    try expectRender(
        "<div class=\"sx-group\">\n<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// box\n\na\n\n// end",
    );
}

test "skinny renders a centered narrow wrapper" {
    try expectRender(
        "<div class=\"sx-group\" style=\"width:75%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// box skinny()\n\na\n\n// end",
    );
    // combined with grid: grid declarations first, then the width
    try expectRender(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem;width:80%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n</div>\n",
        "// g grid(2) skinny(80%)\n\na\n\n// --\n\nb\n\n// end",
    );
}

test "center renders a text-centering wrapper" {
    try expectRender(
        "<div class=\"sx-group\" style=\"text-align:center\">\n" ++
            "<div class=\"sx-group-sec\">\n<h3 id=\"title\">title</h3>\n</div>\n</div>\n",
        "/center()\n\n### title",
    );
    // combined with skinny: width first, then the alignment
    try expectRender(
        "<div class=\"sx-group\" style=\"width:60%;margin-inline:auto;text-align:center\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// box skinny(60%) center()\n\na\n\n// end",
    );
    // center takes no arguments — args deactivate the line
    try expectRender("<p>/center(5)</p>\n", "/center(5)");
}

test "collapse: the first element becomes the summary leader" {
    try expectRender(
        "<details class=\"sx-group sx-collapse\">\n" ++
            "<summary><p><strong>What is strikedown?</strong></p>\n</summary>\n" ++
            "<div class=\"sx-collapse-body\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>A typography-first superset of markdown.</p>\n</div>\n" ++
            "</div>\n</details>\n",
        "// faq collapse()\n\n**What is strikedown?**\n\nA typography-first superset of markdown.\n\n// end faq",
    );
}

test "collapse: open variant; a lone element gets the empty bar" {
    try expectRender(
        "<details class=\"sx-group sx-collapse\" open>\n" ++
            "<summary class=\"sx-collapse-bar\"></summary>\n" ++
            "<div class=\"sx-collapse-body\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>only one paragraph here</p>\n</div>\n" ++
            "</div>\n</details>\n",
        "/collapse(open)\n\nonly one paragraph here",
    );
}

test "collapse: other command styles land on the body, never the details" {
    try expectRender(
        "<details class=\"sx-group sx-collapse\">\n" ++
            "<summary><p>lead</p>\n</summary>\n" ++
            "<div class=\"sx-collapse-body\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n" ++
            "</div>\n</details>\n",
        "// g collapse() grid(2)\n\nlead\n\na\n\n// --\n\nb\n\n// end g",
    );
}

test "collapse: bad args degrade the line to prose" {
    try expectRender("<p>/collapse(true)</p>\n", "/collapse(true)");
}

test "single command wraps the next content element" {
    try expectRender(
        "<div class=\"sx-group\" style=\"width:50%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>narrow para</p>\n</div>\n</div>\n",
        "/skinny(50%)\n\nnarrow para",
    );
    // prose slash lines are untouched
    try expectRender("<p>/usr/bin/env foo</p>\n", "/usr/bin/env foo");
    // a command with nothing to bind to stays prose
    try expectRender("<p>/skinny(50%)</p>\n", "/skinny(50%)");
}

test "chained single commands nest and apply to the next content element" {
    try expectRender(
        "<div class=\"sx-group\" style=\"width:75%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\" style=\"color:var(--accent)\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>heres some skinny colored test</p>\n</div>\n</div>\n" ++
            "</div>\n</div>\n",
        "/skinny()\n/color(accent)\nheres some skinny colored test",
    );
    // a repeated layout command in the chain still hits the layout-level
    // rule: the inner one is stripped and warned, same as two nested groups
    try expectRender(
        "<div class=\"sx-group\" style=\"width:50%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\">\n<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n" ++
            "</div>\n</div>\n",
        "/skinny(50%)\n/skinny(60%)\na",
    );
    // a chain that never reaches a content element reverts to prose
    try expectRender(
        "<p>/skinny(50%)</p>\n<p>/color(accent)</p>\n",
        "/skinny(50%)\n/color(accent)",
    );
}

test "a command nested under itself renders the structure without the layout" {
    try expectRender(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\">\n<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n</div>\n" ++
            "</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>c</p>\n</div>\n</div>\n",
        "// outer grid(2)\n\n// inner grid(2)\na\n// --\nb\n// end\n\n// --\n\nc\n\n// end outer",
    );
}

test "different layout commands nest: skinny inside a grid section" {
    try expectRender(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\" style=\"width:50%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n" ++
            "</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n</div>\n",
        "// outer grid(2)\n\n// inner skinny(50%)\na\n// end\n\n// --\n\nb\n\n// end outer",
    );
}

test "group directive: unclean // lines degrade to prose" {
    try expectRender("<p>// note here</p>\n", "// note here");
    try expectRender("<p>// box glow(5)</p>\n", "// box glow(5)");
    try expectRender("<p>// --</p>\n", "// --");
    try expectRender("<p>// end</p>\n", "// end");
}

test "fenced code language class" {
    try expectRender(
        "<pre><code class=\"language-python\">x = 1\n</code></pre>\n",
        "```python\nx = 1\n```",
    );
    // no info string -> no class attribute (existing behavior)
    try expectRender("<pre><code>x\n</code></pre>\n", "```\nx\n```");
}

test "color command renders a theme-variable wrapper" {
    try expectRender(
        "<div class=\"sx-group\" style=\"color:var(--muted)\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// note color(muted)\n\na\n\n// end",
    );
    // combined with skinny: width first, then the color
    try expectRender(
        "<div class=\"sx-group\" style=\"width:60%;margin-inline:auto;color:var(--accent)\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// box skinny(60%) color(accent)\n\na\n\n// end",
    );
    // single command on a heading
    try expectRender(
        "<div class=\"sx-group\" style=\"color:var(--accent)\">\n" ++
            "<div class=\"sx-group-sec\">\n<h3 id=\"title\">title</h3>\n</div>\n</div>\n",
        "/color(accent)\n\n### title",
    );
    // unknown roles deactivate the line
    try expectRender("<p>/color(red)</p>\n", "/color(red)");
}

test "color span renders an inline-styled span" {
    try expectRender(
        "<p>a <span class=\"sx-color\" style=\"color:var(--accent)\"><strong>big</strong> word</span> b</p>\n",
        "a [**big** word].color(accent) b",
    );
    // a link cannot sit inside a span: the first-`]` scan hands the outer
    // `[` to the link form, byte-identical to plain markdown's parse
    try expectRender(
        "<p><a href=\"https://z.dev\">see [z</a>].color(muted)</p>\n",
        "[see [z](https://z.dev)].color(muted)",
    );
}

test "color span restricted forms degrade to prose" {
    // a link wins its `[` — `.color()` never attaches to a link
    try expectRender(
        "<p><a href=\"https://z.dev\">z</a>.color(accent)</p>\n",
        "[z](https://z.dev).color(accent)",
    );
    // unknown role and escaped bracket stay literal
    try expectRender("<p>[x].color(red)</p>\n", "[x].color(red)");
    try expectRender("<p>[x].color(accent)</p>\n", "\\[x].color(accent)");
}

test "indent: tab prefix renders text-indent steps on the block itself" {
    try expectRender(
        "<p style=\"text-indent:2rem\">indented paragraph</p>\n",
        "\tindented paragraph",
    );
    try expectRender(
        "<h2 id=\"deep-heading\" style=\"text-indent:4rem\">deep heading</h2>\n",
        "\t\t## deep heading",
    );
    // The stripped line is what multi-line parsers re-read: a tabbed quote
    // opener still forms a quote, indented.
    try expectRender(
        "<blockquote style=\"text-indent:2rem\">\n<p>quoted</p>\n</blockquote>\n",
        "\t> quoted",
    );
}

test "indent command renders on groups and single-command wrappers" {
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:4rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>pushed in</p>\n</div>\n</div>\n",
        "/indent(2)\n\npushed in",
    );
    // Indent joins other commands at the end of the declaration order.
    try expectRender(
        "<div class=\"sx-group\" style=\"width:80%;margin-inline:auto;text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// g skinny(80%) indent()\n\na\n\n// end g",
    );
    // Degradation: bad args keep the line prose.
    try expectRender("<p>/indent(0)</p>\n", "/indent(0)");
}

test "indent on a group cascades to each child via CSS inheritance, not per-child attrs" {
    // text-indent is set once on the wrapper; every child paragraph is
    // plain (no style of its own) and picks up its own first-line indent
    // purely by CSS inheritance — the same wrapper-only pattern color()
    // already uses (docs/design/006-color.md).
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>first</p>\n<p>second</p>\n</div>\n</div>\n",
        "// g indent()\n\nfirst\n\nsecond\n\n// end g",
    );
}

test "indent nesting overrides rather than accumulates" {
    // An inner indent(1) inside an outer indent(2) group renders 1 step
    // at that point, not 3 — plain CSS text-indent semantics (011-indent,
    // corrected 2026-07-22): nesting scopes the override, it doesn't stack.
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:4rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>para</p>\n</div>\n</div>\n" ++
            "</div>\n</div>\n",
        "// outer indent(2)\n\n// inner indent()\n\npara\n\n// end inner\n\n// end outer",
    );
}
