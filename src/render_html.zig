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
//!     `docs/reference/design/006-color.md`)
//!
//! The end-to-end `expectRender` tests at the bottom are the renderer's
//! specification — they predate the parse/emit split and must keep passing
//! unchanged.

const std = @import("std");
const strikedown = @import("strikedown.zig");
const sheet = @import("sheet.zig");
const html = @import("html.zig");
const routes = @import("routes.zig");
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
    ///
    /// `null` means **no site**: a doc-relative target is left exactly as
    /// written, because there is no route table for it to resolve against.
    /// That is the right answer for `strike render`, which renders one file
    /// with no project around it — rewriting `other.md` to `/other` there
    /// invents a link to a page that does not exist.
    link_base: ?[]const u8 = null,
    /// The site mount point (yaml `base:`), "" when unmounted. `link_base`
    /// carries it as a prefix; `../` pops in doc-relative links clamp here
    /// instead of at the site root, so no link resolves outside the mount.
    link_floor: []const u8 = "",
};

/// `Options.link_base` + `link_floor`, bundled for the emitter walk.
const LinkCtx = struct { dir: []const u8, floor: []const u8 };

/// A rendered fragment plus the parse-time diagnostics that came with it.
/// The renderer never prints — the caller decides where warnings go (and
/// what file name to blame them on, which only it knows).
pub const Rendered = struct {
    html: []u8,
    warnings: []const []const u8,

    /// The common caller idiom: print each warning to stderr blamed on
    /// `src_path`, free them, and keep just the HTML.
    pub fn takeHtml(r: Rendered, gpa: Allocator, src_path: []const u8) []u8 {
        for (r.warnings) |m| std.debug.print("strike: warning: {s}: {s}\n", .{ src_path, m });
        r.freeWarnings(gpa);
        return r.html;
    }

    pub fn freeWarnings(r: Rendered, gpa: Allocator) void {
        for (r.warnings) |m| gpa.free(m);
        gpa.free(r.warnings);
    }
};

/// Render strikedown/markdown source to an HTML fragment (no surrounding
/// `<html>`/`<body>`). The parse tree lives in an internal arena freed before
/// returning; the caller owns `Rendered.html` and its warnings (both from
/// `gpa` — `takeHtml`/`freeWarnings` above).
pub fn render(gpa: Allocator, src: []const u8, opts: Options) !Rendered {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try strikedown.parse(arena_state.allocator(), src, opts.sheet);
    const out = try emit(gpa, doc, opts);
    errdefer gpa.free(out);
    const warnings = try gpa.alloc([]const u8, doc.warnings.len);
    errdefer gpa.free(warnings);
    var duped: usize = 0;
    errdefer for (warnings[0..duped]) |m| gpa.free(m);
    for (doc.warnings, 0..) |m, i| {
        warnings[i] = try gpa.dupe(u8, m);
        duped = i + 1;
    }
    return .{ .html = out, .warnings = warnings };
}

/// Emit an already-parsed `Doc` as an HTML fragment. Caller owns the result.
pub fn emit(gpa: Allocator, doc: strikedown.Doc, opts: Options) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const ctx: ?LinkCtx = if (opts.link_base) |dir| .{ .dir = dir, .floor = opts.link_floor } else null;
    for (doc.blocks) |block| {
        // An Allocating writer's one failure mode *is* allocation failure —
        // surface it as such instead of leaking the writer-interface error.
        emitBlock(&out.writer, block, ctx, 0) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// The gap between grid sections. A future gap() command would replace this
/// constant with an `Attrs` field read below.
const grid_gap = "1.5rem";

/// How a block realizes `indent` (`docs/reference/design/013-command-realization.md`):
/// flowing prose takes the typographic first-line tab, an element that owns a
/// structural left edge (a list's marker column) shifts as a whole box.
const IndentMode = enum { first_line, box };

/// Emit ` style="…"` (leading space included) from a block's attrs — or
/// nothing at all when every styling attr is unset (structural attrs like
/// `collapse` shape elements instead and never land here). The single owner
/// of CSS declaration order: grid, width, center, color, indent (the order
/// the render tests lock; extend at the end) — and of each command's
/// *realization*, which for `indent` depends on the caller's `mode`.
/// `columns` only ever appears on group blocks — the parser sets attrs
/// nowhere else, and grid arranges sections, which only groups have — so the
/// grid CSS needs no non-group guard.
fn writeStyleAttr(w: *Writer, attrs: strikedown.Attrs, mode: IndentMode) Writer.Error!void {
    if (!attrs.anyStyle()) return;
    try w.writeAll(" style=\"");
    var sep = false;
    if (attrs.columns) |n| {
        try styleSep(w, &sep);
        try w.print("display:grid;grid-template-columns:repeat({d},minmax(0,1fr));gap:" ++ grid_gap, .{n});
    }
    if (attrs.width_pct) |pct| {
        try styleSep(w, &sep);
        // skinny (≤ 100%) centers with auto margins; wide (> 100%) overflows
        // its container, where `auto` computes to 0 and would push the box
        // off to one side — the explicit negative calc bleeds it evenly.
        if (pct <= 100) {
            try w.print("width:{d}%;margin-inline:auto", .{pct});
        } else {
            try w.print("width:{d}%;margin-inline:calc((100% - {d}%) / 2)", .{ pct, pct });
        }
    }
    if (attrs.centered) {
        try styleSep(w, &sep);
        try w.writeAll("text-align:center");
    }
    if (attrs.text_color) |role| {
        try styleSep(w, &sep);
        try w.print("color:var(--{t})", .{role});
    }
    if (attrs.indent != 0) {
        try styleSep(w, &sep);
        switch (mode) {
            .first_line => try w.print("text-indent:{d}rem", .{attrs.indent * 2}),
            // The reset stops an ancestor group's inherited `text-indent`
            // from nudging the contents of an already-shifted box.
            .box => try w.print("margin-left:{d}rem;text-indent:0", .{attrs.indent * 2}),
        }
    }
    try w.writeByte('"');
}

/// Joins style declarations: a `;` before every one but the first.
fn styleSep(w: *Writer, sep: *bool) Writer.Error!void {
    if (sep.*) try w.writeByte(';');
    sep.* = true;
}

/// Emit one block. `inherited_indent` is the indent steps an enclosing group
/// carries: the HTML backend renders a group's indent once on its wrapper and
/// lets CSS inheritance reach every descendant's first line, but a box-mode
/// element (a list) has to realize the same value itself, so the value is
/// carried down rather than left entirely to the cascade. Inner wins — a
/// block's own `attrs.indent` overrides what it inherited, matching the
/// language's scoping rule.
fn emitBlock(w: *Writer, block: strikedown.Block, link_base: ?LinkCtx, inherited_indent: usize) Writer.Error!void {
    const indent = if (block.attrs.indent != 0) block.attrs.indent else inherited_indent;
    switch (block.kind) {
        .heading => |h| {
            try w.print("<h{d} id=\"", .{h.level});
            try escapeAttrInto(w, h.id);
            try w.writeByte('"');
            try writeStyleAttr(w, block.attrs, .first_line);
            try w.writeByte('>');
            try emitInlines(w, h.inlines, link_base);
            try w.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |inls| {
            try w.writeAll("<p");
            try writeStyleAttr(w, block.attrs, .first_line);
            try w.writeByte('>');
            try emitInlines(w, inls, link_base);
            try w.writeAll("</p>\n");
        },
        .quote => |q| {
            try w.writeAll("<blockquote");
            if (q.alert) |a| try w.print(" class=\"sx-alert sx-alert-{t}\"", .{a});
            try writeStyleAttr(w, block.attrs, .first_line);
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
        .list => |list| {
            // A list owns its marker column, so `indent` shifts the whole
            // list rather than the item text (013-command-realization).
            var attrs = block.attrs;
            attrs.indent = indent;
            try emitList(w, list, attrs, link_base);
        },
        .code => |code| {
            try w.writeAll("<pre");
            try writeStyleAttr(w, block.attrs, .first_line);
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
            try writeStyleAttr(w, block.attrs, .first_line);
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
            try writeStyleAttr(w, block.attrs, .first_line);
            try w.writeAll("/>\n");
        },
        .group => |g| {
            if (block.attrs.citations) return emitCitations(w, g, block.attrs, link_base, indent);
            if (block.attrs.collapse) |c| return emitCollapse(w, g, c, block.attrs, link_base, indent);
            // Styles are inline (not shell CSS) so fragments and static
            // exports are self-contained; the classes are hooks for future
            // reader styling.
            try w.writeAll("<div class=\"sx-group\"");
            try writeStyleAttr(w, block.attrs, .first_line);
            try w.writeAll(">\n");
            try emitSections(w, g.sections, link_base, indent, false);
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
fn emitCollapse(w: *Writer, g: strikedown.Group, c: strikedown.Collapse, attrs: strikedown.Attrs, link_base: ?LinkCtx, indent: usize) Writer.Error!void {
    // `<summary>`'s content model is phrasing content, so only a paragraph
    // or heading leader can supply it (as its inlines, unwrapped); a group
    // led by a list/table/anything block-shaped keeps the whole body folded
    // behind the empty bar instead of emitting invalid HTML.
    var total: usize = 0;
    for (g.sections) |section| total += section.len;
    const leader: ?strikedown.Block = if (total >= 2 and g.sections[0].len > 0) switch (g.sections[0][0].kind) {
        .paragraph, .heading => g.sections[0][0],
        else => null,
    } else null;
    try w.writeAll("<details class=\"sx-group sx-collapse\"");
    if (c == .open) try w.writeAll(" open");
    try w.writeAll(">\n");
    if (leader) |b| {
        try w.writeAll("<summary>");
        switch (b.kind) {
            .paragraph => |inls| try emitInlines(w, inls, link_base),
            .heading => |h| try emitInlines(w, h.inlines, link_base),
            else => unreachable,
        }
        try w.writeAll("</summary>\n");
    } else {
        try w.writeAll("<summary class=\"sx-collapse-bar\"></summary>\n");
    }
    try w.writeAll("<div class=\"sx-collapse-body\"");
    try writeStyleAttr(w, attrs, .first_line);
    try w.writeAll(">\n");
    try emitSections(w, g.sections, link_base, indent, leader != null);
    try w.writeAll("</div>\n</details>\n");
}

/// Walk a group's sections into `sx-group-sec` wrappers — the one section
/// walk every group-shaped element shares. `skip_leader` drops the first
/// block of the first section (a collapse already emitted it as its summary).
fn emitSections(w: *Writer, sections: []const []strikedown.Block, link_base: ?LinkCtx, indent: usize, skip_leader: bool) Writer.Error!void {
    for (sections, 0..) |section, si| {
        try w.writeAll("<div class=\"sx-group-sec\">\n");
        const body = if (skip_leader and si == 0) section[1..] else section;
        for (body) |b| try emitBlock(w, b, link_base, indent);
        try w.writeAll("</div>\n");
    }
}

/// The document's citations group (016-citations): a `<section>` the reader
/// styles as a bibliography. The walk is the plain group walk — the entry
/// list's anchors and backlinks arrive as data on its items
/// (`Item.cite_entry`/`cite_sites`, written by the parse-end pass), which
/// `emitList` reads wherever the list sits.
fn emitCitations(w: *Writer, g: strikedown.Group, attrs: strikedown.Attrs, link_base: ?LinkCtx, indent: usize) Writer.Error!void {
    try w.writeAll("<section class=\"sx-group sx-citations\"");
    try writeStyleAttr(w, attrs, .first_line);
    try w.writeAll(">\n");
    try emitSections(w, g.sections, link_base, indent, false);
    try w.writeAll("</section>\n");
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
/// aren't `Block`s and can't carry attrs — the recursion passes `.{}`, which
/// also keeps a sublist from re-applying an indent its parent already shifted.
fn emitList(w: *Writer, list: strikedown.List, attrs: strikedown.Attrs, link_base: ?LinkCtx) Writer.Error!void {
    try w.writeAll(if (list.ordered) "<ol" else "<ul");
    // Raw lists render markerless; the class is the hook, reader CSS
    // removes bullets and marker indentation (008-raw-lists).
    if (list.plain) try w.writeAll(" class=\"sx-plain\"");
    try writeStyleAttr(w, attrs, .box);
    if (list.ordered and list.start != 1) {
        try w.print(" start=\"{d}\"", .{list.start});
    }
    try w.writeAll(">\n");
    for (list.items) |item| {
        // A citation entry (016-citations) carries its anchor and backlink
        // sites as data from the parse-end pass.
        if (item.cite_entry != 0) {
            try w.print("<li id=\"cite-{d}\">", .{item.cite_entry});
        } else {
            try w.writeAll("<li>");
        }
        if (item.task) |checked| {
            try w.writeAll(if (checked)
                "<input type=\"checkbox\" disabled checked> "
            else
                "<input type=\"checkbox\" disabled> ");
        }
        try emitInlines(w, item.text, link_base);
        // Backlinks hug the entry's own text — before any nested sublist,
        // or a `↩` would drop onto its own line after the `</ul>`.
        var backlinks_pending = item.cite_sites.len > 0;
        for (item.tail) |tail| switch (tail) {
            .line => |inls| {
                try w.writeByte(' ');
                try emitInlines(w, inls, link_base);
            },
            .list => |sub| {
                if (backlinks_pending) {
                    try writeBacklinks(w, item.cite_sites);
                    backlinks_pending = false;
                }
                try w.writeByte('\n');
                try emitList(w, sub, .{}, link_base);
            },
        };
        if (backlinks_pending) try writeBacklinks(w, item.cite_sites);
        try w.writeAll("</li>\n");
    }
    try w.writeAll(if (list.ordered) "</ol>\n" else "</ul>\n");
}

fn writeBacklinks(w: *Writer, sites: []const u32) Writer.Error!void {
    for (sites) |site| {
        try w.print(" <a class=\"sx-cite-back\" href=\"#cite-ref-{d}\">\u{21a9}</a>", .{site});
    }
}

/// One `<th>`/`<td>` with its alignment style and inline content.
fn writeCell(w: *Writer, tag: []const u8, al: strikedown.Align, inls: []const strikedown.Inline, link_base: ?LinkCtx) Writer.Error!void {
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

fn emitInlines(w: *Writer, inls: []const strikedown.Inline, link_base: ?LinkCtx) Writer.Error!void {
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
            // A disallowed scheme drops the element; the alt text stays as
            // prose (same inert degradation as an unsafe link).
            if (!safeHref(img.src)) return escapeInto(w, img.alt);
            try w.writeAll("<img src=\"");
            try escapeAttrInto(w, img.src);
            try w.writeAll("\" alt=\"");
            try escapeAttrInto(w, img.alt);
            try w.writeAll("\">");
        },
        .link => |l| {
            // A disallowed scheme (javascript:, data:, …) keeps the text
            // and drops the link — exported pages must never carry live
            // script in an href.
            if (!safeHref(l.url)) return emitInlines(w, l.children, link_base);
            try w.writeAll("<a href=\"");
            // Only a renderer that knows the site rewrites doc-relative
            // targets; with no `link_base` there is no route to rewrite to,
            // so the target stays exactly as the author wrote it.
            if (link_base) |ctx| {
                if (docLinkPath(l.url)) |path| {
                    try writeDocHref(w, ctx, path, l.url[path.len..]);
                } else {
                    try escapeAttrInto(w, l.url);
                }
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
        .cite_span => |span| {
            // The whole span links to its first resolved entry — the claim is
            // the click/hover target (016-citations) — with the mark's numbers
            // set superscript after it. A mark with nothing resolved renders
            // inert: a plain span, raw ref text in the sup. A claim that
            // *contains* a link also takes the span form — an `<a>` inside an
            // `<a>` is invalid HTML and browsers split it — leaving the sup
            // numbers as the click targets.
            const resolved: ?u32 = for (span.refs) |ref| {
                if (ref.num != 0) break ref.num;
            } else null;
            const first: ?u32 = if (containsLink(span.children)) null else resolved;
            if (first) |num| {
                try w.print("<a class=\"sx-cite\" id=\"cite-ref-{d}\" href=\"#cite-{d}\"", .{ span.site, num });
                if (span.preview.len > 0) {
                    try w.writeAll(" title=\"");
                    try escapeAttrInto(w, span.preview);
                    try w.writeByte('"');
                }
                try w.writeByte('>');
            } else {
                try w.writeAll("<span class=\"sx-cite\">");
            }
            try emitInlines(w, span.children, link_base);
            try w.writeAll(if (first != null) "</a>" else "</span>");
            try w.writeAll("<sup class=\"sx-cite-mark\">");
            for (span.refs, 0..) |ref, ri| {
                if (ri > 0) try w.writeByte(',');
                if (ref.num != 0) {
                    try w.print("<a href=\"#cite-{d}\">{d}</a>", .{ ref.num, ref.num });
                } else {
                    try escapeInto(w, ref.raw);
                }
            }
            try w.writeAll("</sup>");
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

/// May `url` land in an `href`/`src` attribute? Relative paths, fragments,
/// site-absolute paths, and http/https/mailto pass; every other scheme —
/// `javascript:`, `data:`, `vbscript:`, anything unknown — fails, as does any
/// URL carrying control characters (browsers strip them *inside* scheme
/// names, so `java\tscript:` would otherwise sneak through). Rejected
/// targets render unlinked; the usual inert degradation.
fn safeHref(url: []const u8) bool {
    for (url) |c| if (c < 0x20 or c == 0x7f) return false;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    // A colon after a path/query/fragment delimiter is not a scheme colon.
    if (std.mem.indexOfAny(u8, url[0..colon], "/?#") != null) return true;
    const scheme = url[0..colon];
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "mailto");
}

/// True when any inline (recursively) is a link or autolink — what decides
/// that a citation mark can't take its `<a>` form.
fn containsLink(inls: []const strikedown.Inline) bool {
    for (inls) |inl| switch (inl) {
        .link, .autolink => return true,
        .strong, .em, .strong_em, .strike => |c| if (containsLink(c)) return true,
        .color_span => |cs| if (containsLink(cs.children)) return true,
        .cite_span => |s| if (containsLink(s.children)) return true,
        .text, .code, .math, .image => {},
    };
    return false;
}

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

/// Emit the route a doc-relative link resolves to (`routes.resolveDocTarget`
/// owns the path rules — pops clamped at the mount floor, extension strip,
/// main collapse). `suffix` is the target's `#fragment`/`?query` tail,
/// appended untouched.
fn writeDocHref(w: *Writer, ctx: LinkCtx, path: []const u8, suffix: []const u8) Writer.Error!void {
    const t = routes.resolveDocTarget(ctx.dir, path, ctx.floor);
    if (t.stem.len == 0) {
        if (t.base.len == 0) try w.writeByte('/') else try escapeAttrInto(w, t.base);
    } else {
        try escapeAttrInto(w, t.base);
        try w.writeByte('/');
        try escapeAttrInto(w, t.stem);
    }
    try escapeAttrInto(w, suffix);
}

fn expectRender(expected: []const u8, md: []const u8) !void {
    try expectRenderAt(null, expected, md);
}

/// Renders and compares, and asserts the source parsed *clean* — a test whose
/// input intentionally warns uses `expectRenderWarn` instead.
fn expectRenderAt(link_base: ?[]const u8, expected: []const u8, md: []const u8) !void {
    const r = try render(std.testing.allocator, md, .{ .link_base = link_base });
    defer std.testing.allocator.free(r.html);
    defer r.freeWarnings(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, r.html);
    for (r.warnings) |m| std.debug.print("unexpected warning: {s}\n", .{m});
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
}

/// Renders and compares, and asserts that one of the parse warnings contains
/// `warn_substring` — the degradation-path counterpart of `expectRender`.
fn expectRenderWarn(expected: []const u8, md: []const u8, warn_substring: []const u8) !void {
    const r = try render(std.testing.allocator, md, .{});
    defer std.testing.allocator.free(r.html);
    defer r.freeWarnings(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, r.html);
    for (r.warnings) |m| {
        if (std.mem.indexOf(u8, m, warn_substring) != null) return;
    }
    std.debug.print("no warning containing \"{s}\"; got {d}:\n", .{ warn_substring, r.warnings.len });
    for (r.warnings) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedWarning;
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
    // non-Latin headings keep their text, so they get distinct ids instead of
    // both collapsing onto the "section" fallback
    try expectRender(
        "<h1 id=\"中文\">中文</h1>\n<h1 id=\"日本語\">日本語</h1>\n",
        "# 中文\n\n# 日本語",
    );
    try expectRender("<h2 id=\"café\">Café</h2>\n", "## Café");
}

test "paragraph joins soft-wrapped lines" {
    try expectRender("<p>one two</p>\n", "one\ntwo");
    try expectRender("<p>a</p>\n<p>b</p>\n", "a\n\nb");
}

test "inline spans may open on one soft-wrapped line and close on a later one" {
    try expectRender("<p><em>asdf asdf</em></p>\n", "*asdf\nasdf*");
    try expectRender("<p>a <strong>b c</strong> d</p>\n", "a **b\nc** d");
    try expectRender("<p><code>x y</code></p>\n", "`x\ny`");
    try expectRender(
        "<blockquote>\n<p>q <em>e m</em></p>\n</blockquote>\n",
        "> q *e\n> m*",
    );
    try expectRender("<ul>\n<li><em>one two</em></li>\n</ul>\n", "- *one\n  two*");
}

test "inline bold, italic and code" {
    try expectRender("<p><strong>b</strong> and <em>i</em></p>\n", "**b** and *i*");
    try expectRender("<p>use <code>x &lt; y</code></p>\n", "use `x < y`");
}

test "triple-star renders nested bold+italic, not a leftover asterisk" {
    try expectRender("<p><strong><em>both</em></strong></p>\n", "***both***");
    try expectRender("<p>a <strong><em>b</em></strong> c</p>\n", "a ***b*** c");
}

// The canonical examples of docs/reference/design/014-flanking.md, end to end.

test "flanking: asterisks in prose render literally" {
    try expectRender("<p>a * b * c</p>\n", "a * b * c");
    try expectRender("<p>5 * 4 * 3</p>\n", "5 * 4 * 3");
    try expectRender("<p>~~ not strike ~~</p>\n", "~~ not strike ~~");
    // …while hugging delimiters still emphasize.
    try expectRender("<p><em>emphasis</em></p>\n", "*emphasis*");
    try expectRender("<p><strong>\"quoted\"</strong></p>\n", "**\"quoted\"**");
    try expectRender("<p>intra<em>word</em>em</p>\n", "intra*word*em");
    try expectRender("<p><del>struck</del></p>\n", "~~struck~~");
    // A candidate closer that can't close is skipped, not fatal.
    try expectRender("<p><em>a * b</em></p>\n", "*a * b*");
}

test "flanking: prose dollars render literally, real math still typesets" {
    try expectRender(
        "<p>The book costs $5 and the pen costs $10.</p>\n",
        "The book costs $5 and the pen costs $10.",
    );
    try expectRender("<p>then $HOME and $PATH are set</p>\n", "then $HOME and $PATH are set");
    try expectRender("<p>$ x $</p>\n", "$ x $");
    try expectRender("<p>real math \\(x^2\\) inline</p>\n", "real math $x^2$ inline");
}

test "links" {
    try expectRender(
        "<p><a href=\"https://z.dev\">Zig</a></p>\n",
        "[Zig](https://z.dev)",
    );
}

test "doc-relative .md/.sx links resolve to routes" {
    // from the site root: extension drops, subfolder path survives
    try expectRenderAt(
        "",
        "<p><a href=\"/design/001-groups\">groups</a></p>\n",
        "[groups](design/001-groups.md)",
    );
    try expectRenderAt("", "<p><a href=\"/notes\">n</a></p>\n", "[n](notes.sx)");
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
    try expectRenderAt(
        "",
        "<p><a href=\"/spec#anchors\">s</a></p>\n",
        "[s](spec.md#anchors)",
    );
    // main.* links land on the containing folder's own route
    try expectRenderAt("/p", "<p><a href=\"/p/sub\">s</a></p>\n", "[s](sub/main.md)");
    try expectRenderAt("/p", "<p><a href=\"/p\">home</a></p>\n", "[home](main.md)");
    try expectRenderAt("", "<p><a href=\"/\">home</a></p>\n", "[home](main.md)");
}

test "without a site, doc-relative targets are left exactly as written" {
    // `strike render` has no project around the file and so no route table.
    // Rewriting here used to invent `/other`, a link to a page that does not
    // exist; the source stays a working file link instead.
    try expectRender("<p><a href=\"other.md\">o</a></p>\n", "[o](other.md)");
    try expectRender("<p><a href=\"notes.sx\">n</a></p>\n", "[n](notes.sx)");
    try expectRender(
        "<p><a href=\"design/spec.md#anchors\">s</a></p>\n",
        "[s](design/spec.md#anchors)",
    );
    try expectRender("<p><a href=\"../up.md\">u</a></p>\n", "[u](../up.md)");
    // Everything that never rewrote is unaffected either way.
    try expectRender("<p><a href=\"https://z.dev\">z</a></p>\n", "[z](https://z.dev)");
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

test "a list of links and code spans renders every item intact" {
    // Regression: items share one flow buffer, and code/link inlines slice
    // their input — earlier items used to render overwritten bytes.
    try expectRenderAt(
        "",
        "<ul>\n<li><a href=\"/one\">a</a> <code>code</code></li>\n" ++
            "<li><a href=\"/two\">b</a> <code>more</code></li>\n</ul>\n",
        "- [a](one.md) `code`\n- [b](two.md) `more`",
    );
    try expectRenderAt(
        "",
        "<blockquote>\n<p><a href=\"/one\">a</a> <code>code</code></p>\n" ++
            "<p><a href=\"/two\">b</a></p>\n</blockquote>\n",
        "> [a](one.md) `code`\n>\n> [b](two.md)",
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
    // GFM splits cells before parsing inlines, so a pipe inside a code span
    // needs the same escape — and since code bodies are never inline-parsed,
    // the cell splitter is what has to undo it. Previously this kept a
    // literal backslash in the rendered `<code>`.
    try expectRender(
        "<table>\n<thead>\n<tr><th><code>a|b</code></th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>x</td></tr>\n</tbody>\n</table>\n",
        "| `a\\|b` |\n|---|\n| x |",
    );
    // An escaped *backslash* before a pipe leaves the pipe a real delimiter:
    // two cells, the first ending in a literal backslash.
    try expectRender(
        "<table>\n<thead>\n<tr><th>a\\</th><th>b</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>x</td><td>y</td></tr>\n</tbody>\n</table>\n",
        "| a\\\\|b |\n|---|---|\n| x | y |",
    );
    // An *unescaped* pipe still splits, code span or not — GFM's rule, so a
    // table renders the same here as it does on GitHub.
    try expectRender(
        "<table>\n<thead>\n<tr><th>`a</th><th>b`</th></tr>\n</thead>\n<tbody>\n" ++
            "<tr><td>x</td><td>y</td></tr>\n</tbody>\n</table>\n",
        "| `a|b` |\n|---|---|\n| x | y |",
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

test "wide renders a wrapper that bleeds evenly into both margins" {
    // Over 100% the box overflows its container, where `margin-inline:auto`
    // computes to 0 and would push it all to one side — hence the calc.
    try expectRender(
        "<div class=\"sx-group\" style=\"width:125%;margin-inline:calc((100% - 125%) / 2)\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n",
        "// figure wide()\n\na\n\n// end",
    );
    // Same slot in the declaration order skinny occupies: grid, then width.
    try expectRender(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem;width:150%;margin-inline:calc((100% - 150%) / 2)\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n</div>\n",
        "// g grid(2) wide(150%)\n\na\n\n// --\n\nb\n\n// end",
    );
    // Degradation: skinny's range and a missing % keep the line prose.
    try expectRender("<p>// g wide(100%)</p>\n", "// g wide(100%)");
    try expectRender("<p>/wide(150)</p>\n", "/wide(150)");
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
            "<summary><strong>What is strikedown?</strong></summary>\n" ++
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
            "<summary>lead</summary>\n" ++
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

test "citations: the canonical example — mark links, entry anchors, backlink" {
    // 016-citations: the span is the click/hover target, the sup carries the
    // number, the entry anchors and links back, the list sits in a
    // bibliography section.
    try expectRender(
        "<p><a class=\"sx-cite\" id=\"cite-ref-1\" href=\"#cite-1\" " ++
            "title=\"1. D. Knuth, The TeXbook, Addison-Wesley, 1984.\">" ++
            "Line-breaking is best solved as a dynamic program</a>" ++
            "<sup class=\"sx-cite-mark\"><a href=\"#cite-1\">1</a></sup>" ++
            " — a result that predates the system it was written for.</p>\n" ++
            "<section class=\"sx-group sx-citations\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol>\n" ++
            "<li id=\"cite-1\">D. Knuth, <em>The TeXbook</em>, Addison-Wesley, 1984. " ++
            "<a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a></li>\n" ++
            "</ol>\n" ++
            "</div>\n" ++
            "</section>\n",
        "[Line-breaking is best solved as a dynamic program].cite(1) — a result that predates the system it was written for.\n" ++
            "\n// citations()\n\n1. D. Knuth, *The TeXbook*, Addison-Wesley, 1984.\n\n//",
    );
}

test "citations: multi-source marks and key binding" {
    try expectRender(
        "<p><a class=\"sx-cite\" id=\"cite-ref-1\" href=\"#cite-1\" " ++
            "title=\"1. a.\n2. b.\">both</a>" ++
            "<sup class=\"sx-cite-mark\"><a href=\"#cite-1\">1</a>,<a href=\"#cite-2\">2</a></sup></p>\n" ++
            "<section class=\"sx-group sx-citations\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol>\n" ++
            "<li id=\"cite-1\">a. <a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a></li>\n" ++
            "<li id=\"cite-2\">b. <a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a></li>\n" ++
            "</ol>\n" ++
            "</div>\n" ++
            "</section>\n",
        "[both].cite(1, k)\n\n// citations()\n\n1. a.\n2. [k] b.\n\n//",
    );
}

test "citations: unresolved marks render inert; malformed marks stay prose" {
    // no citations group: a plain span, the raw ref in the sup, no links
    try expectRenderWarn(
        "<p><span class=\"sx-cite\">x</span><sup class=\"sx-cite-mark\">3</sup></p>\n",
        "[x].cite(3)",
        "no citations group",
    );
    // malformed args deactivate the whole mark — literal prose, the
    // degradation an older strike shows for every citation
    try expectRender("<p>[x].cite()</p>\n", "[x].cite()");
    try expectRender("<p>[].cite(1)</p>\n", "[].cite(1)");
}

test "citations: a second group degrades to a plain group" {
    try expectRenderWarn(
        "<section class=\"sx-group sx-citations\">\n" ++
            "<div class=\"sx-group-sec\">\n<ol>\n<li id=\"cite-1\">first</li>\n</ol>\n</div>\n" ++
            "</section>\n" ++
            "<div class=\"sx-group\">\n" ++
            "<div class=\"sx-group-sec\">\n<ol>\n<li>second</li>\n</ol>\n</div>\n" ++
            "</div>\n",
        "// citations()\n\n1. first\n\n//\n\n// citations()\n\n1. second\n\n//",
        "citations ignored",
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
    try expectRenderWarn(
        "<div class=\"sx-group\" style=\"width:50%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\">\n<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n</div>\n" ++
            "</div>\n</div>\n",
        "/skinny(50%)\n/skinny(60%)\na",
        "skinny ignored",
    );
    // a chain that never reaches a content element reverts to prose
    try expectRender(
        "<p>/skinny(50%)</p>\n<p>/color(accent)</p>\n",
        "/skinny(50%)\n/color(accent)",
    );
}

test "a command nested under itself renders the structure without the layout" {
    try expectRenderWarn(
        "<div class=\"sx-group\" style=\"display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.5rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\">\n<div class=\"sx-group-sec\">\n<p>a</p>\n</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>b</p>\n</div>\n</div>\n" ++
            "</div>\n" ++
            "<div class=\"sx-group-sec\">\n<p>c</p>\n</div>\n</div>\n",
        "// outer grid(2)\n\n// inner grid(2)\na\n// --\nb\n// end\n\n// --\n\nc\n\n// end outer",
        "grid ignored",
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

// The canonical examples of docs/reference/design/015-paragraph-indent.md, end to end.

test "indent: a whitespace-led paragraph renders one step, whatever the whitespace" {
    try expectRender(
        "<p style=\"text-indent:2rem\">indented paragraph</p>\n",
        "  indented paragraph",
    );
    try expectRender(
        "<p style=\"text-indent:2rem\">indented paragraph</p>\n",
        "\tindented paragraph",
    );
    // Four spaces and two tabs are still one step — depth is `indent(n)`'s job.
    try expectRender("<p style=\"text-indent:2rem\">deep</p>\n", "    deep");
    try expectRender("<p style=\"text-indent:2rem\">deep</p>\n", "\t\tdeep");
    try expectRender("<p>flush</p>\n", "flush");
}

test "indent: leading whitespace before a non-paragraph form changes nothing" {
    try expectRender("<h2 id=\"heading\">heading</h2>\n", "  ## heading");
    try expectRender("<blockquote>\n<p>quoted</p>\n</blockquote>\n", "\t> quoted");
    try expectRender("<ul>\n<li>item</li>\n</ul>\n", "  - item");
    try expectRender("<hr/>\n", "\t---");
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
    // already uses (docs/reference/design/006-color.md).
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>first</p>\n<p>second</p>\n</div>\n</div>\n",
        "// g indent()\n\nfirst\n\nsecond\n\n// end g",
    );
}

test "indent on a list shifts the whole list, markers included" {
    // A list owns its marker column, so the box moves rather than the item
    // text — a text-indent here would drop the tab *between* the number and
    // the item (013-command-realization). The reset keeps the wrapper's
    // inherited text-indent from reaching the item text as well. (A tab
    // prefix can't reach a list: note 011 leaves it as list nesting, so the
    // command forms are how a list is ever indented.)
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol style=\"margin-left:2rem;text-indent:0\">\n<li>one</li>\n<li>two</li>\n</ol>\n" ++
            "</div>\n</div>\n",
        "/indent()\n\n1. one\n2. two",
    );
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:4rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ul style=\"margin-left:4rem;text-indent:0\">\n<li>item</li>\n</ul>\n" ++
            "</div>\n</div>\n",
        "/indent(2)\n\n- item",
    );
}

test "a group's indent reaches a list child as a box shift, a paragraph as a first line" {
    // The wrapper still carries text-indent for flowing prose (the
    // paragraph stays styleless and inherits); the list realizes the same
    // inherited value in its own mode.
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n<p>lead-in</p>\n" ++
            "<ul style=\"margin-left:2rem;text-indent:0\">\n<li>item</li>\n</ul>\n" ++
            "</div>\n</div>\n",
        "// g indent()\n\nlead-in\n\n- item\n\n// end g",
    );
    // Inner wins: a nested indent overrides what it inherited, for the list too.
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<div class=\"sx-group\" style=\"text-indent:4rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ul style=\"margin-left:4rem;text-indent:0\">\n<li>item</li>\n</ul>\n" ++
            "</div>\n</div>\n" ++
            "</div>\n</div>\n",
        "// g indent()\n\n/indent(2)\n\n- item\n\n// end g",
    );
}

test "a sublist inside an indented list is not shifted again" {
    try expectRender(
        "<div class=\"sx-group\" style=\"text-indent:2rem\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ul style=\"margin-left:2rem;text-indent:0\">\n<li>outer\n" ++
            "<ul>\n<li>inner</li>\n</ul>\n</li>\n</ul>\n" ++
            "</div>\n</div>\n",
        "/indent()\n\n- outer\n  - inner",
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

// ---- v0.1.0 fixes ------------------------------------------------------------

test "href scheme allowlist: script schemes render unlinked" {
    // javascript:/data:/vbscript: (any casing) drop the <a>, keep the text
    try expectRender("<p>x</p>\n", "[x](javascript:alert(1))");
    try expectRender("<p>x</p>\n", "[x](JaVaScRiPt:alert(1))");
    try expectRender("<p>x</p>\n", "[x](data:text/html;base64,PGI+)");
    try expectRender("<p>x</p>\n", "[x](vbscript:msgbox)");
    // control characters can't smuggle a scheme past the check
    try expectRender("<p>x</p>\n", "[x](java\tscript:alert(1))");
    // the allowlist and non-scheme shapes still link
    try expectRender("<p><a href=\"https://z.dev\">x</a></p>\n", "[x](https://z.dev)");
    try expectRender("<p><a href=\"mailto:a@b.c\">x</a></p>\n", "[x](mailto:a@b.c)");
    try expectRender("<p><a href=\"/abs/path\">x</a></p>\n", "[x](/abs/path)");
    try expectRender("<p><a href=\"#frag\">x</a></p>\n", "[x](#frag)");
    // a colon past a slash is not a scheme
    try expectRender("<p><a href=\"a/b:c\">x</a></p>\n", "[x](a/b:c)");
}

test "img scheme allowlist: an unsafe src degrades to the alt text" {
    try expectRender("<p>diagram</p>\n", "![diagram](javascript:alert(1))");
    try expectRender(
        "<p><img src=\"pix/ok.png\" alt=\"diagram\"></p>\n",
        "![diagram](pix/ok.png)",
    );
}

test "cite mark containing a link takes the span form (no nested <a>)" {
    try expectRender(
        "<section class=\"sx-group sx-citations\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol>\n<li id=\"cite-1\">Entry. <a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a></li>\n</ol>\n" ++
            "</div>\n</section>\n" ++
            "<p><span class=\"sx-cite\">see <a href=\"https://z.dev\">https://z.dev</a></span>" ++
            "<sup class=\"sx-cite-mark\"><a href=\"#cite-1\">1</a></sup></p>\n",
        "// refs citations()\n\n1. Entry.\n\n//\n\n[see https://z.dev].cite(1)",
    );
}

test "doc links clamp at the mount floor, not the site root" {
    const opts: Options = .{ .link_base = "/mnt/docs/p/sub", .link_floor = "/mnt/docs" };
    const r = try render(std.testing.allocator, "[up](../one.md) [out](../../../../x.md)", opts);
    defer std.testing.allocator.free(r.html);
    defer r.freeWarnings(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<p><a href=\"/mnt/docs/p/one\">up</a> <a href=\"/mnt/docs/x\">out</a></p>\n",
        r.html,
    );
}

test "collapse: a block-shaped leader keeps the empty bar (summary is phrasing content)" {
    try expectRender(
        "<details class=\"sx-group sx-collapse\">\n" ++
            "<summary class=\"sx-collapse-bar\"></summary>\n" ++
            "<div class=\"sx-collapse-body\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n" ++
            "<p>after</p>\n</div>\n" ++
            "</div>\n</details>\n",
        "// c collapse()\n\n- a\n- b\n\nafter\n\n// end c",
    );
}

test "citations: the backlink lands before an entry's nested sublist" {
    try expectRender(
        "<section class=\"sx-group sx-citations\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol>\n<li id=\"cite-1\">Entry. <a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a>\n" ++
            "<ul>\n<li>note</li>\n</ul>\n</li>\n</ol>\n" ++
            "</div>\n</section>\n" ++
            "<p><a class=\"sx-cite\" id=\"cite-ref-1\" href=\"#cite-1\" title=\"1. Entry.\">x</a>" ++
            "<sup class=\"sx-cite-mark\"><a href=\"#cite-1\">1</a></sup></p>\n",
        "// refs citations()\n\n1. Entry.\n  - note\n\n//\n\n[x].cite(1)",
    );
}

test "citations: numbering follows the entry list's start end-to-end" {
    try expectRender(
        "<section class=\"sx-group sx-citations\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol start=\"3\">\n<li id=\"cite-3\">Third. <a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a></li>\n</ol>\n" ++
            "</div>\n</section>\n" ++
            "<p><a class=\"sx-cite\" id=\"cite-ref-1\" href=\"#cite-3\" title=\"3. Third.\">x</a>" ++
            "<sup class=\"sx-cite-mark\"><a href=\"#cite-3\">3</a></sup></p>\n",
        "// refs citations()\n\n3. Third.\n\n//\n\n[x].cite(3)",
    );
}

test "emit() renders a pre-parsed Doc (the two-stage seam)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const doc = try strikedown.parse(arena_state.allocator(), "# T\n\nbody", .empty);
    const out = try emit(std.testing.allocator, doc, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("<h1 id=\"t\">T</h1>\n<p>body</p>\n", out);
}

test "citations() composes with a styling command on the same opener" {
    try expectRender(
        "<section class=\"sx-group sx-citations\" style=\"width:80%;margin-inline:auto\">\n" ++
            "<div class=\"sx-group-sec\">\n" ++
            "<ol>\n<li id=\"cite-1\">Entry. <a class=\"sx-cite-back\" href=\"#cite-ref-1\">\u{21a9}</a></li>\n</ol>\n" ++
            "</div>\n</section>\n" ++
            "<p><a class=\"sx-cite\" id=\"cite-ref-1\" href=\"#cite-1\" title=\"1. Entry.\">x</a>" ++
            "<sup class=\"sx-cite-mark\"><a href=\"#cite-1\">1</a></sup></p>\n",
        "// refs citations() skinny(80%)\n\n1. Entry.\n\n//\n\n[x].cite(1)",
    );
}

test "render survives allocation failure at every point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            const r = try render(alloc,
                "# T\n\n- a\n  - b\n\n| h |\n|---|\n| \\| |\n\n[x].cite(1) *em* `c`\n\n// refs citations()\n\n1. [k] E.\n\n//", .{});
            r.freeWarnings(alloc);
            alloc.free(r.html);
        }
    }.f, .{});
}
