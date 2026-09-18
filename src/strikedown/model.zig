//! The strikedown document model: the `Doc` tree every block/inline parser
//! builds and every emitter walks. Pure types plus `alignAt`; no I/O, no
//! parsing logic. Split out of `strikedown.zig` — see that file's own doc
//! comment for the pipeline this feeds.

const std = @import("std");
const command = @import("command.zig");

// ---- document model ----------------------------------------------------------

pub const Doc = struct {
    blocks: []Block,
    /// Parse-time diagnostics (e.g. a `grid(n)` section-count mismatch):
    /// flat human-readable arena strings in discovery order, deliberately
    /// unstructured — callers print them, nothing branches on them (grow a
    /// typed field only when a structured consumer exists). `parse` stays
    /// pure — callers decide whether to print.
    warnings: []const []const u8 = &.{},
};

/// One block-level element — a *content element*, or a group arranging
/// content elements. Shared command-derived attributes live in `attrs`
/// beside the structural payload in `kind`, so every block type gets them
/// uniformly; today only group blocks carry non-default attrs.
pub const Block = struct {
    kind: Kind,
    attrs: Attrs = .{},

    pub const Kind = union(enum) {
        heading: Heading,
        paragraph: []Inline,
        quote: Quote,
        list: List,
        code: Code,
        table: Table,
        /// Raw display-math TeX (multi-line joined with '\n'), not escaped.
        math: []const u8,
        rule,
        spacer,
        group: Group,
    };
};

/// Command-derived presentation attributes. Commands write these fields
/// (`applyCommand`), emitters read them through one shared style helper —
/// data all the way, never emitter special cases. Today group blocks
/// (including `/cmd()` desugarings) carry non-default attrs, plus any
/// paragraph whose first line is whitespace-indented (note 015); future
/// element-type-specific commands (`// ###.color(accent)`) will write these
/// same fields onto heading/paragraph/… blocks with no further model change.
pub const Attrs = struct {
    columns: ?usize = null, // from grid(n) (layout)
    flow_columns: ?usize = null, // from flow(n): sequential column flow across pages
    width_pct: ?usize = null, // from skinny(N%) or wide(N%): % of the body column
    // width (layout). One field, two commands: ≤ 100 was written by skinny,
    // > 100 by wide — the grammar keeps the ranges disjoint (see `Command.wide`)
    centered: bool = false, // from center(): center-align contained text (layout)
    text_color: ?TextColor = null, // from color(role): theme text color (non-layout)
    collapse: ?Collapse = null, // from collapse(): fold behind the leader (layout, structural)
    citations: bool = false, // from citations(): the group holds the document's
    // reference list (layout, structural); one per document — the parse-end
    // pass (`resolveCitations`) strips extras with a warning
    indent: usize = 0, // from indent(n), or one step from a whitespace-indented
    // paragraph (note 015): first-line indent steps,
    // rendered as CSS text-indent — affects a block's own first line only, and on a
    // group cascades to each child via CSS inheritance (non-layout)
    caption_pos: ?CaptionPos = null, // from caption()/caption(pos): the
    // figcaption's position relative to its backward-attached partner
    // (structural, non-layout, note 018) — bare caption() is .bottom
    caption_split_pct: ?usize = null, // from caption(left|right, N%): the
    // caption column's % share of figure width; only meaningful when
    // caption_pos is .left or .right (defaulted at parse time otherwise null)
    snug: bool = false, // from snug(): backward-attaches like caption, but
    // purely to remove the vertical seam between the popped partner and
    // this group's own content — no figure semantics, no positional data
    // (structural, non-layout, note 019). Mutually exclusive with caption
    // on the same opener: combining them degrades the whole line to prose
    // (both want the one popped-partner slot).

    /// True when any command set a field. Runs over the exhaustive
    /// `hasCommand` switch, so a new command can never be forgotten here.
    pub fn any(a: Attrs) bool {
        for (std.meta.tags(command.CommandTag)) |t| {
            if (command.hasCommand(a, t)) return true;
        }
        return false;
    }

    /// True when any *styling* command set a field — the emitter's "does
    /// this block need a style attribute" check. Structural commands
    /// (`collapse`) shape the emitted elements instead and never produce
    /// style declarations.
    pub fn anyStyle(a: Attrs) bool {
        for (std.meta.tags(command.CommandTag)) |t| {
            if (!command.isStructural(t) and command.hasCommand(a, t)) return true;
        }
        return false;
    }

    /// True when a *backward-attach* command set a field (`caption`,
    /// `snug`) — the parser's "does this group pop its preceding sibling"
    /// check (`strikedown.appendSibling`) and its mirror, "can this ever
    /// bind forward as a `/cmd()` directive" (never — `parseSingleCommand`
    /// rejects it outright). Runs over the exhaustive `isBackwardAttach`
    /// switch, so a third backward-attach command can never be forgotten.
    pub fn backwardAttach(a: Attrs) bool {
        for (std.meta.tags(command.CommandTag)) |t| {
            if (command.isBackwardAttach(t) and command.hasCommand(a, t)) return true;
        }
        return false;
    }
};

/// A group's structural payload: named sections of content. The group's
/// commands land on its `Block.attrs` (data, not emitter special cases) —
/// a group whose attrs carry a layout command *is* a layout element; one
/// carrying only `color` is a styled container; one with no commands is a
/// plain container. A single-command directive (`/cmd()`) produces this
/// same node: nameless, one section holding the one element it binds to.
pub const Group = struct {
    name: []const u8, // "" = nameless (runs to EOF unless closed)
    sections: [][]Block,
};

/// A theme color role (`docs/reference/design/006-color.md`). Strikedown never names
/// concrete colors — a role resolves to whatever the reader's active theme
/// defines for it (HTML: `var(--accent)` etc.), so colored text tracks theme
/// switches; other backends map roles to their own palettes.
pub const TextColor = enum {
    accent,
    muted,
    fg,

    pub fn parse(name: []const u8) ?TextColor {
        return std.meta.stringToEnum(TextColor, name);
    }
};

/// A collapsible group's initial state (`docs/reference/design/007-collapse.md`).
/// `collapse()` folds the group closed behind its leader; `collapse(open)`
/// starts it open. State is per page load — nothing persists.
pub const Collapse = enum { closed, open };

/// Where a caption sits relative to its backward-attached partner
/// (`docs/reference/design/018-image-captions-v2.md`). Bare `caption()` is `.bottom`.
pub const CaptionPos = enum { top, bottom, left, right };

pub const Heading = struct {
    level: usize, // 1..6
    id: []const u8, // slugified anchor, deduped per document
    inlines: []Inline,
};

/// A blockquote, optionally typed as an alert (`docs/reference/design/009-alerts.md`).
pub const Quote = struct {
    /// Set when the quote's first content is an `[!TYPE]` marker; unknown
    /// types leave the quote plain (the marker stays literal text).
    alert: ?Alert = null,
    /// The quote's paragraphs: consecutive `>` lines merge into one,
    /// a bare `>` line separates them.
    paras: [][]Inline,
};

/// An alert type: the GFM five plus the strike extras. Matched
/// case-insensitively; renderers title the quote with it.
pub const Alert = enum { note, tip, important, warning, caution, todo, example, question };

pub const Code = struct {
    lang: []const u8, // "" if the fence had no info string
    text: []const u8, // verbatim body, every line '\n'-terminated
};

pub const List = struct {
    ordered: bool,
    /// A raw list (`. ` items, `docs/reference/design/008-raw-lists.md`): unordered,
    /// rendered with no item marker. Marker kinds don't mix at one level.
    plain: bool = false,
    /// The first item's written number (GFM: it sets the list start; later
    /// item numbers are ignored). Always 1 for unordered lists.
    start: usize,
    items: []Item,
};

pub const Item = struct {
    /// null = plain item; true/false = checked/unchecked task box.
    task: ?bool = null,
    /// The marker line's inline content.
    text: []Inline,
    /// Continuation segments in source order: soft-wrapped lines and nested lists.
    tail: []Tail = &.{},
    /// Set by the citations pass on the entry list's items (016-citations):
    /// this item's 1-based entry number — its anchor identity. 0 = not an entry.
    cite_entry: u32 = 0,
    /// Mark sites (`CiteSpan.site`) citing this entry, in document order —
    /// the entry's backlink targets.
    cite_sites: []const u32 = &.{},

    pub const Tail = union(enum) {
        line: []Inline,
        list: List,
    };
};

pub const Table = struct {
    /// Per-column alignment from the separator row (may be shorter/longer than
    /// the header; index with `alignAt`).
    aligns: []Align,
    header: [][]Inline,
    /// Body rows, each already padded/truncated to `header.len` cells.
    rows: [][][]Inline,
};

pub const Align = enum { none, left, center, right };

pub const Inline = union(enum) {
    /// Literal text (backslash escapes already unwrapped). Emitters escape it.
    text: []const u8,
    code: []const u8,
    /// Raw inline-math TeX.
    math: []const u8,
    image: struct { src: []const u8, alt: []const u8 },
    link: struct { url: []const u8, children: []Inline },
    /// A URL that is both target and label (`<http…>` or a bare URL).
    autolink: []const u8,
    strong: []Inline,
    em: []Inline,
    strong_em: []Inline,
    strike: []Inline,
    /// `[text].color(role)` — a colored span (`docs/reference/design/006-color.md`).
    color_span: struct { color: TextColor, children: []Inline },
    /// `[text].cite(refs)` — a citation mark binding the span to entries in
    /// the document's `citations()` group (`docs/reference/design/016-citations.md`).
    cite_span: CiteSpan,
};

/// A citation mark's payload. The inline parser writes `refs` (a digit ref
/// carries its number immediately; a key ref waits); `site`, final ref
/// resolution, and `preview` are written by the parse-end citations pass
/// (`resolveCitations`), so every backend walks an already-resolved tree.
pub const CiteSpan = struct {
    refs: []CiteRef,
    /// 1-based document-order index of this mark — the anchor identity entry
    /// backlinks point at. 0 until the resolution pass runs.
    site: u32 = 0,
    /// Plain-text rendering of the resolved entries ("1. …\n4. …") for
    /// renderers that want a hover affordance; empty when nothing resolved.
    preview: []const u8 = "",
    children: []Inline,
};

/// One reference inside a citation mark: `raw` exactly as written; `num` the
/// 1-based entry position it resolves to, or 0 while unresolved (a key ref
/// before the pass — or permanently: unknown key, out of range, no citations
/// group — and the mark renders an unresolved ref inert, as its raw text).
pub const CiteRef = struct {
    raw: []const u8,
    num: u32 = 0,
};

pub fn alignAt(aligns: []const Align, i: usize) Align {
    return if (i < aligns.len) aligns[i] else .none;
}
