//! Strikedown's command vocabulary: the `Command` union, its `word(args)`
//! parser, and the classifier switches every new command must extend
//! (`isLayout`/`isStructural`/`hasCommand`/`clearCommand`, all exhaustive
//! over `CommandTag`). Free functions over `Attrs`/`Command` — no parser
//! state. Split out of `strikedown.zig`; see that file's own doc comment for
//! the extension recipe this machinery exists to serve. Alias resolution
//! (design note 010) plugs in here: an alias resolves at definition time by
//! feeding its tokens through `parseCommand`/`applyCommand`, so it never
//! grows a new `Command` variant.

const std = @import("std");
const model = @import("model.zig");

const Attrs = model.Attrs;
const TextColor = model.TextColor;
const Collapse = model.Collapse;
const CaptionPos = model.CaptionPos;

/// The recognized commands. A new command is a variant here, a
/// `parseCommand` arm, an `Attrs` field written by an `applyCommand` arm,
/// its `isLayout`/`isStructural`/`hasCommand`/`clearCommand` arms
/// (exhaustive switches — the compiler finds them for you), and the emitter
/// reading the field (the style helper for styling commands, the element
/// shape for structural ones) — data all the way, per the extension recipe. The depth
/// machinery, `//`-opener and `/cmd()` support, and `Attrs.any` come free.
/// A *layout* command creates a layout element, and its tag keys a
/// `Parser.layout_depth` counter for the per-command layout-level rule
/// (`stripNestedLayout`/`enterLayout`); a non-layout command (`color`)
/// simply never touches a counter, so it nests freely.
pub const Command = union(enum) {
    grid: usize,
    /// skinny(N%): render at N% of the body column width, centered.
    /// Writes `width_pct` — see `wide` for the shared-field invariant.
    skinny: usize,
    /// wide(N%): render at N% of the body column width, centered — the
    /// mirror of `skinny`, bleeding evenly into both margins. Both commands
    /// write the one `Attrs.width_pct` field and the grammar keeps their
    /// ranges disjoint: a value ≤ 100 was written by `skinny`, > 100 by
    /// `wide`. That invariant is what `hasCommand`/`clearCommand` read.
    wide: usize,
    /// center(): center-align text within the surrounding layout element.
    center,
    /// color(role): set the contained text's theme color. Non-layout —
    /// nested colors are meaningful (inner wins by cascade).
    color: TextColor,
    /// collapse(): fold the group behind its leader, closed by default;
    /// collapse(open) starts open. Layout and *structural* — it shapes the
    /// emitted elements rather than adding style declarations.
    collapse: Collapse,
    /// citations(): declare the group's numbered list as the document's
    /// reference list (016-citations) — entries become anchor targets and
    /// `[text].cite(refs)` marks resolve to them. Layout and *structural*,
    /// like `collapse`: it shapes the emitted elements. One per document —
    /// the layout-level rule covers nesting, `resolveCitations` covers
    /// siblings.
    citations,
    /// indent(n): a first-line typographic tab indent, n steps; a
    /// whitespace-indented paragraph writes one step of the same data
    /// (011-indent, 015-paragraph-indent).
    /// Non-layout — nesting scopes, it doesn't stack: an inner indent(n)
    /// overrides the inherited value for its own subtree (plain CSS
    /// text-indent semantics), the same as color's inner-wins cascade.
    indent: usize,
    /// caption()/caption(pos)/caption(left|right, N%): a `//`-opener-only
    /// group that backward-attaches to its immediately preceding sibling
    /// block, wrapping the pair in a `<figure>` with this group's own content
    /// as the `<figcaption>` (`docs/reference/design/018-image-captions-v2.md`).
    /// Bare `caption()` is `.bottom`. `left`/`right` take an optional split
    /// percent (the caption column's share of the figure's width; defaulted
    /// when omitted) — meaningless combined with `top`/`bottom`, which
    /// `parseCommand` rejects outright (degrades the whole directive line).
    /// Non-layout — a captioned pair nests inside `grid`/`skinny` exactly
    /// like an uncaptioned one. Structural, like `collapse`/`citations`: it
    /// shapes the emitted elements rather than adding style declarations.
    /// Never valid as a `/cmd()` single-command directive (`parseSingleCommand`
    /// rejects it) — backward-attach needs a full group, not a forward wrap.
    caption: struct { pos: CaptionPos, split_pct: ?usize },
};

/// The width the bare forms mean, and the range bounds that keep the two
/// commands' shared field tellable-apart (`skinny_max_pct` is the divide:
/// skinny ≤ 100 < wide — the disjoint-range invariant `hasCommand` reads).
const skinny_default_pct = 75;
const wide_default_pct = 125;
const skinny_max_pct = 100;
const wide_max_pct = 200;

/// Argument caps for the unbounded-looking commands (provisional defaults,
/// like skinny's 75). Anything past them is no real layout, and the caps keep
/// emitter arithmetic (`indent * 2`) far from overflow.
const max_grid_cols = 12;
const max_indent_steps = 8;

/// caption(left|right)'s implicit split when no percent is given.
pub const caption_default_split_pct = 30;

/// Parse one `word(args)` token, null if it isn't a recognized command with
/// valid args (which deactivates the whole line — strict, so typos are seen).
pub fn parseCommand(tok: []const u8) ?Command {
    if (tok.len < 3 or tok[tok.len - 1] != ')') return null;
    const paren = std.mem.indexOfScalar(u8, tok, '(') orelse return null;
    const word = tok[0..paren];
    const args = tok[paren + 1 .. tok.len - 1];
    if (std.mem.eql(u8, word, "grid")) {
        const n = std.fmt.parseInt(usize, args, 10) catch return null;
        if (n == 0 or n > max_grid_cols) return null;
        return .{ .grid = n };
    }
    if (std.mem.eql(u8, word, "skinny")) {
        if (args.len == 0) return .{ .skinny = skinny_default_pct }; // bare skinny(): the default width
        if (args[args.len - 1] != '%') return null;
        const n = std.fmt.parseInt(usize, args[0 .. args.len - 1], 10) catch return null;
        if (n == 0 or n > skinny_max_pct) return null;
        return .{ .skinny = n };
    }
    if (std.mem.eql(u8, word, "wide")) {
        if (args.len == 0) return .{ .wide = wide_default_pct }; // bare wide(): the default width
        if (args[args.len - 1] != '%') return null;
        const n = std.fmt.parseInt(usize, args[0 .. args.len - 1], 10) catch return null;
        if (n <= skinny_max_pct or n > wide_max_pct) return null; // 100% and below is skinny's range
        return .{ .wide = n };
    }
    if (std.mem.eql(u8, word, "center")) {
        if (args.len != 0) return null; // center() takes no arguments
        return .center;
    }
    if (std.mem.eql(u8, word, "color")) {
        const role = TextColor.parse(args) orelse return null;
        return .{ .color = role };
    }
    if (std.mem.eql(u8, word, "collapse")) {
        if (args.len == 0) return .{ .collapse = .closed }; // collapse(): closed by default
        if (std.mem.eql(u8, args, "open")) return .{ .collapse = .open };
        return null;
    }
    if (std.mem.eql(u8, word, "citations")) {
        if (args.len != 0) return null; // citations() takes no arguments
        return .citations;
    }
    if (std.mem.eql(u8, word, "indent")) {
        if (args.len == 0) return .{ .indent = 1 }; // bare indent(): one step
        const n = std.fmt.parseInt(usize, args, 10) catch return null;
        if (n == 0 or n > max_indent_steps) return null;
        return .{ .indent = n };
    }
    if (std.mem.eql(u8, word, "caption")) {
        if (args.len == 0) return .{ .caption = .{ .pos = .bottom, .split_pct = null } };
        const comma = std.mem.indexOfScalar(u8, args, ',');
        const pos_str = std.mem.trim(u8, if (comma) |c| args[0..c] else args, " ");
        const pos = std.meta.stringToEnum(CaptionPos, pos_str) orelse return null;
        if (comma) |c| {
            if (pos != .left and pos != .right) return null; // % only meaningful for a side position
            const pct_str = std.mem.trim(u8, args[c + 1 ..], " ");
            if (pct_str.len == 0 or pct_str[pct_str.len - 1] != '%') return null;
            const n = std.fmt.parseInt(usize, pct_str[0 .. pct_str.len - 1], 10) catch return null;
            if (n == 0 or n >= 100) return null;
            return .{ .caption = .{ .pos = pos, .split_pct = n } };
        }
        const split: ?usize = if (pos == .left or pos == .right) caption_default_split_pct else null;
        return .{ .caption = .{ .pos = pos, .split_pct = split } };
    }
    return null;
}

pub fn applyCommand(attrs: *Attrs, cmd: Command) void {
    switch (cmd) {
        .grid => |n| attrs.columns = n,
        .skinny, .wide => |n| attrs.width_pct = n,
        .center => attrs.centered = true,
        .color => |role| attrs.text_color = role,
        .collapse => |c| attrs.collapse = c,
        .citations => attrs.citations = true,
        .indent => |n| attrs.indent = n,
        .caption => |c| {
            attrs.caption_pos = c.pos;
            attrs.caption_split_pct = c.split_pct;
        },
    }
}

pub const CommandTag = std.meta.Tag(Command);

/// Layout commands create layout elements and count under the per-command
/// layout-level rule; non-layout commands (`color`) style without creating
/// one and nest freely. Exhaustive: a new `Command` variant is a compile
/// error here until classified.
pub fn isLayout(tag: CommandTag) bool {
    return switch (tag) {
        .grid, .skinny, .wide, .center, .collapse, .citations => true,
        .color, .indent, .caption => false,
    };
}

/// Structural commands are expressed by the emitter's *element* choice
/// (collapse -> a disclosure element), never as style declarations —
/// `Attrs.anyStyle` skips them so they don't produce empty style attributes.
/// Exhaustive, like `isLayout`.
pub fn isStructural(tag: CommandTag) bool {
    return switch (tag) {
        .collapse, .citations, .caption => true,
        .grid, .skinny, .wide, .center, .color, .indent => false,
    };
}

/// Does `attrs` carry `tag`'s command — is the field it writes set?
pub fn hasCommand(attrs: Attrs, tag: CommandTag) bool {
    return switch (tag) {
        .grid => attrs.columns != null,
        // The disjoint-range invariant (see `Command.wide`): one field, and
        // which side of 100 the value sits on names the command that wrote it.
        .skinny => attrs.width_pct != null and attrs.width_pct.? <= skinny_max_pct,
        .wide => attrs.width_pct != null and attrs.width_pct.? > skinny_max_pct,
        .center => attrs.centered,
        .color => attrs.text_color != null,
        .collapse => attrs.collapse != null,
        .citations => attrs.citations,
        .indent => attrs.indent != 0,
        .caption => attrs.caption_pos != null,
    };
}

/// Unset the field `tag`'s command writes (the layout-level rule strips
/// colliding commands with this).
pub fn clearCommand(attrs: *Attrs, tag: CommandTag) void {
    switch (tag) {
        .grid => attrs.columns = null,
        // Each clears the shared width field only when the value is on its
        // own side of 100 (the disjoint-range invariant).
        .skinny, .wide => if (hasCommand(attrs.*, tag)) {
            attrs.width_pct = null;
        },
        .center => attrs.centered = false,
        .color => attrs.text_color = null,
        .collapse => attrs.collapse = null,
        .citations => attrs.citations = false,
        .indent => attrs.indent = 0,
        .caption => {
            attrs.caption_pos = null;
            attrs.caption_split_pct = null;
        },
    }
}

pub fn groupLabel(name: []const u8) []const u8 {
    return if (name.len > 0) name else "(nameless)";
}

/// True when `name` is one of the fixed command words (`grid`, `skinny`, …) —
/// reserved against aliasing (`docs/reference/design/010-aliases.md`) so a
/// `name()` use is unambiguous: either a real command or an alias, never both.
pub fn isCommandWord(name: []const u8) bool {
    return std.meta.stringToEnum(CommandTag, name) != null;
}

/// Copy every field an alias's precomputed `Attrs` set onto `dst`, leaving
/// fields it left at their default untouched — the same effect as replaying
/// the alias's original commands through `applyCommand` one at a time
/// (`docs/reference/design/010-aliases.md`: aliases resolve to `Attrs` at
/// definition time, so a *use* just merges that snapshot).
pub fn mergeAttrs(dst: *Attrs, src: Attrs) void {
    if (src.columns) |v| dst.columns = v;
    if (src.width_pct) |v| dst.width_pct = v;
    if (src.centered) dst.centered = true;
    if (src.text_color) |v| dst.text_color = v;
    if (src.collapse) |v| dst.collapse = v;
    if (src.citations) dst.citations = true;
    if (src.indent != 0) dst.indent = src.indent;
    if (src.caption_pos) |v| dst.caption_pos = v;
    if (src.caption_split_pct) |v| dst.caption_split_pct = v;
}

/// Splits an opener line's `<command>*` tail on spaces like
/// `std.mem.tokenizeScalar`, except a space inside a command's `(...)` never
/// ends a token — needed since a command argument (`caption(left, 30%)`) can
/// itself contain a space. Shared by the `//` group-opener parser and the
/// `:name command()*` alias-definition parser (`sheet.zig`).
pub const CommandTokenizer = struct {
    rest: []const u8,
    i: usize = 0,

    pub fn next(self: *CommandTokenizer) ?[]const u8 {
        while (self.i < self.rest.len and self.rest[self.i] == ' ') self.i += 1;
        if (self.i >= self.rest.len) return null;
        const start = self.i;
        var depth: usize = 0;
        while (self.i < self.rest.len) : (self.i += 1) {
            switch (self.rest[self.i]) {
                '(' => depth += 1,
                ')' => if (depth > 0) {
                    depth -= 1;
                },
                ' ' => if (depth == 0) break,
                else => {},
            }
        }
        return self.rest[start..self.i];
    }
};

/// Classify a (left-trimmed) line as a single-command directive
/// (`docs/reference/design/002-single-command.md`): `/` immediately followed by exactly
/// one command token and nothing else. The char after the slash keeps the two
/// directive families apart (`//` is a group line), and `parseCommand`'s
/// strictness is the degradation story — `/usr/bin/env`, `/skinny (50%)`, or
/// trailing words all return null and stay prose.
pub fn parseSingleCommandLine(t: []const u8) ?Command {
    if (t.len < 2 or t[0] != '/' or t[1] == '/') return null;
    return parseCommand(std.mem.trimEnd(u8, t[1..], " "));
}
