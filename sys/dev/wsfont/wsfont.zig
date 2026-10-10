// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Kernel font support.
//
// This is the Zig counterpart of NetBSD's sys/dev/wsfont/wsfont.c, simplified:
// NetBSD keeps a registry of fonts that can be looked up by geometry and
// encoding, because fonts can be loaded at run time. ZenBSD currently ships a
// single built-in font, so only the Font descriptor and a glyph accessor are
// defined here; the registry will grow when fonts can be loaded.

/// A bitmap font.
pub const Font: type = struct {
    /// Human-readable name.
    name: []const u8,
    /// First character code covered.
    firstchar: u8,
    /// Number of glyphs covered.
    numchars: u16,
    /// Glyph width in pixels.
    width: u8,
    /// Glyph height in pixels.
    height: u8,
    /// Bytes per glyph row.
    stride: u8,
    /// Glyph bitmap: numchars glyphs, each height * stride bytes, one row per
    /// line, leftmost pixel in the most significant bit.
    data: []const u8,
};

/// Return the bitmap for `ch`, or null when the font does not cover it.
pub fn glyph(font: *const Font, ch: u8) ?[]const u8 {
    if (ch < font.firstchar) {
        return null;
    }
    const index: usize = ch - font.firstchar;
    if (index >= font.numchars) {
        return null;
    }
    const bytes_per_glyph: usize = @as(usize, font.height) * font.stride;
    const offset: usize = index * bytes_per_glyph;
    return font.data[offset .. offset + bytes_per_glyph];
}
