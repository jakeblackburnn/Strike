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
//!   - a group's layout attributes (`columns`, `width_pct`) land as inline
//!     `style` declarations on its `sx-group` wrapper
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
};

/// Render strikedown/markdown source to an HTML fragment (no surrounding
/// `<html>`/`<body>`). The parse tree lives in an internal arena freed before
/// returning; the caller owns the returned slice and frees it with `gpa`.
pub fn render(gpa: Allocator, src: []const u8, opts: Options) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try strikedown.parse(arena_state.allocator(), src, opts.sheet);
    for (doc.warnings) |warning| std.debug.print("strike: warning: {s}\n", .{warning});
    return emit(gpa, doc);
}

/// Emit an already-parsed `Doc` as an HTML fragment. Caller owns the result.
pub fn emit(gpa: Allocator, doc: strikedown.Doc) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (doc.blocks) |block| try emitBlock(&out.writer, block);
    return out.toOwnedSlice();
}

fn emitBlock(w: *Writer, block: strikedown.Block) Writer.Error!void {
    switch (block.kind) {
        .heading => |h| {
            try w.print("<h{d} id=\"", .{h.level});
            try escapeAttrInto(w, h.id);
            try w.writeAll("\">");
            try emitInlines(w, h.inlines);
            try w.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |inls| {
            try w.writeAll("<p>");
            try emitInlines(w, inls);
            try w.writeAll("</p>\n");
        },
        .quote => |paras| {
            try w.writeAll("<blockquote>\n");
            for (paras) |inls| {
                try w.writeAll("<p>");
                try emitInlines(w, inls);
                try w.writeAll("</p>\n");
            }
            try w.writeAll("</blockquote>\n");
        },
        .list => |list| try emitList(w, list),
        .code => |code| {
            if (code.lang.len > 0) {
                try w.writeAll("<pre><code class=\"language-");
                try escapeAttrInto(w, code.lang);
                try w.writeAll("\">");
            } else {
                try w.writeAll("<pre><code>");
            }
            try escapeInto(w, code.text);
            try w.writeAll("</code></pre>\n");
        },
        .table => |table| {
            try w.writeAll("<table>\n<thead>\n<tr>");
            for (table.header, 0..) |cell, ci| {
                try writeCell(w, "th", strikedown.alignAt(table.aligns, ci), cell);
            }
            try w.writeAll("</tr>\n</thead>\n<tbody>\n");
            for (table.rows) |row| {
                try w.writeAll("<tr>");
                for (row, 0..) |cell, ci| {
                    try writeCell(w, "td", strikedown.alignAt(table.aligns, ci), cell);
                }
                try w.writeAll("</tr>\n");
            }
            try w.writeAll("</tbody>\n</table>\n");
        },
        .math => |tex| {
            try w.writeAll("\\[");
            try escapeInto(w, tex);
            try w.writeAll("\\]\n");
        },
        .rule => try w.writeAll("<hr/>\n"),
        .group => |g| {
            // Styles are inline (not shell CSS) so fragments and static
            // exports are self-contained; the classes are hooks for future
            // reader styling.
            try w.writeAll("<div class=\"sx-group\"");
            if (g.columns != null or g.width_pct != null) {
                try w.writeAll(" style=\"");
                if (g.columns) |n| {
                    try w.print("display:grid;grid-template-columns:repeat({d},minmax(0,1fr));gap:1.5rem", .{n});
                    if (g.width_pct != null) try w.writeByte(';');
                }
                if (g.width_pct) |pct| {
                    try w.print("width:{d}%;margin-inline:auto", .{pct});
                }
                try w.writeByte('"');
            }
            try w.writeAll(">\n");
            for (g.sections) |section| {
                try w.writeAll("<div class=\"sx-group-sec\">\n");
                for (section) |b| try emitBlock(w, b);
                try w.writeAll("</div>\n");
            }
            try w.writeAll("</div>\n");
        },
    }
}

fn emitList(w: *Writer, list: strikedown.List) Writer.Error!void {
    if (list.ordered and list.start != 1) {
        try w.print("<ol start=\"{d}\">\n", .{list.start});
    } else {
        try w.writeAll(if (list.ordered) "<ol>\n" else "<ul>\n");
    }
    for (list.items) |item| {
        try w.writeAll("<li>");
        if (item.task) |checked| {
            try w.writeAll(if (checked)
                "<input type=\"checkbox\" disabled checked> "
            else
                "<input type=\"checkbox\" disabled> ");
        }
        try emitInlines(w, item.text);
        for (item.tail) |tail| switch (tail) {
            .line => |inls| {
                try w.writeByte(' ');
                try emitInlines(w, inls);
            },
            .list => |sub| {
                try w.writeByte('\n');
                try emitList(w, sub);
            },
        };
        try w.writeAll("</li>\n");
    }
    try w.writeAll(if (list.ordered) "</ol>\n" else "</ul>\n");
}

/// One `<th>`/`<td>` with its alignment style and inline content.
fn writeCell(w: *Writer, tag: []const u8, al: strikedown.Align, inls: []const strikedown.Inline) Writer.Error!void {
    try w.writeByte('<');
    try w.writeAll(tag);
    switch (al) {
        .none => {},
        .left => try w.writeAll(" style=\"text-align:left\""),
        .center => try w.writeAll(" style=\"text-align:center\""),
        .right => try w.writeAll(" style=\"text-align:right\""),
    }
    try w.writeByte('>');
    try emitInlines(w, inls);
    try w.writeAll("</");
    try w.writeAll(tag);
    try w.writeByte('>');
}

fn emitInlines(w: *Writer, inls: []const strikedown.Inline) Writer.Error!void {
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
            try escapeAttrInto(w, l.url);
            try w.writeAll("\">");
            try emitInlines(w, l.children);
            try w.writeAll("</a>");
        },
        .autolink => |url| {
            try w.writeAll("<a href=\"");
            try escapeAttrInto(w, url);
            try w.writeAll("\">");
            try escapeInto(w, url);
            try w.writeAll("</a>");
        },
        .strong => |c| {
            try w.writeAll("<strong>");
            try emitInlines(w, c);
            try w.writeAll("</strong>");
        },
        .em => |c| {
            try w.writeAll("<em>");
            try emitInlines(w, c);
            try w.writeAll("</em>");
        },
        .strong_em => |c| {
            try w.writeAll("<strong><em>");
            try emitInlines(w, c);
            try w.writeAll("</em></strong>");
        },
        .strike => |c| {
            try w.writeAll("<del>");
            try emitInlines(w, c);
            try w.writeAll("</del>");
        },
    };
}

// ---- tests ------------------------------------------------------------------
// The renderer's end-to-end specification, unchanged across the parse/emit
// split (it used to live in markdown.zig's single-pass renderer).

fn expectRender(expected: []const u8, md: []const u8) !void {
    const got = try render(std.testing.allocator, md, .{});
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
