//! The strikedown document model, v0.0.1: the `Doc` tree `parse.zig` builds
//! and `emit_html.zig` walks. Pure types; no I/O, no parsing logic.
//!
//! Deliberately small — four block forms (three content elements plus the
//! one superset form, groups), four inline forms — because this is the
//! base: everything not implemented is a backlog entry (`dev/terms.md`),
//! not an oversight. `Block` is a bare union here, not `struct { kind,
//! attrs }`; the split arrives with the first command (see `dev/terms.md`,
//! "Block shape, expected next").

const std = @import("std");

pub const Doc = struct {
    blocks: []Block,
    /// Parse-time diagnostics, flat human-readable arena strings in
    /// discovery order — deliberately unstructured, callers print them,
    /// nothing branches on them. Empty at v0.0.1 (nothing yet produces a
    /// warning), but the field exists from day one: diagnostics-over-fatal
    /// is architectural, not a later addition.
    warnings: []const []const u8 = &.{},
};

/// One block-level element.
pub const Block = union(enum) {
    heading: Heading,
    paragraph: []Inline,
    code: Code,
    /// A `//` group directive (`dev/terms.md`, "group / section /
    /// directive") — the one strikedown superset form in this base. Carries
    /// no commands and no `Attrs`; it is a plain named container, nothing
    /// more, until a command exists to write onto it.
    group: Group,
};

pub const Group = struct {
    name: []const u8,
    /// Sections in source order, split by `===`. A group with no `===`
    /// inside it has exactly one section.
    sections: [][]Block,
};

pub const Heading = struct {
    level: u8, // 1..6
    inlines: []Inline,
    // No anchor `id` yet — slugification is backlog.
};

pub const Code = struct {
    lang: []const u8, // "" if the fence had no info string
    text: []const u8, // verbatim body, never inline-parsed
};

pub const Inline = union(enum) {
    /// Literal text. Emitters escape it.
    text: []const u8,
    code: []const u8,
    strong: []Inline,
    em: []Inline,
};
