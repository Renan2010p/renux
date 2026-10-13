// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Raster operations.
//
// The Zig counterpart of NetBSD's sys/dev/rasops (rasops.c with the per-depth
// rasops15/24/32.c folded in). It describes a linear framebuffer, turns RGB
// colours into pixels for its channel layout, and draws what a text console
// needs: solid rectangles, font glyphs, procedurally drawn box-drawing and
// block characters, and row copies for scrolling.
//
// Every primitive is specialised at compile time for the pixel size (2, 3 or
// 4 bytes), so the inner loops write each pixel exactly once with no per-pixel
// depth test.

const wsfont: type = @import("../wsfont/wsfont.zig");

/// A framebuffer the kernel can draw on.
pub const Raster: type = struct {
    /// Start of the framebuffer, already mapped and writable.
    base: [*]u8,
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
    /// Bytes per scanline.
    stride: u32,
    /// Bits per pixel.
    depth: u8,
    /// Colour channel masks, as reported by the bootloader.
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

/// True when the raster has a depth these routines can draw on (15/16, 24 or
/// 32 bits per pixel, direct colour). Palette (8-bit) modes are not supported.
pub fn supported(raster: *const Raster) bool {
    return switch (raster.depth) {
        15, 16, 24, 32 => raster.red_mask_size != 0 and raster.green_mask_size != 0 and
            raster.blue_mask_size != 0,
        else => false,
    };
}

/// Bytes per pixel.
pub fn bytesPerPixel(raster: *const Raster) u32 {
    return (@as(u32, raster.depth) + 7) / 8;
}

/// Number of whole text columns that fit, given a font cell width.
pub fn cols(raster: *const Raster, cell_width: u8) u32 {
    return raster.width / cell_width;
}

/// Number of whole text rows that fit, given a font cell height.
pub fn rows(raster: *const Raster, cell_height: u8) u32 {
    return raster.height / cell_height;
}

/// Scale one 8-bit colour component into a channel of `mask_size` bits at
/// `mask_shift`. Channels wider than 8 bits (10-bit "deep colour") replicate
/// the top bits so white stays white.
fn channel(component: u8, mask_size: u8, mask_shift: u8) u32 {
    if (mask_size == 0 or mask_size > 16) {
        return 0;
    }
    const c: u32 = component;
    const scaled: u32 = if (mask_size <= 8)
        c >> @intCast(8 - mask_size)
    else
        (c << @intCast(mask_size - 8)) | (c >> @intCast(16 - mask_size));
    return scaled << @intCast(mask_shift);
}

/// Build a framebuffer pixel from an RGB triple.
pub fn pixel(raster: *const Raster, red: u8, green: u8, blue: u8) u32 {
    return channel(red, raster.red_mask_size, raster.red_mask_shift) |
        channel(green, raster.green_mask_size, raster.green_mask_shift) |
        channel(blue, raster.blue_mask_size, raster.blue_mask_shift);
}

/// Build a framebuffer pixel from a packed 0xRRGGBB colour.
pub fn pixelRgb(raster: *const Raster, rgb: u32) u32 {
    return pixel(raster, @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb));
}

// -- Pixel access, specialised per pixel size --------------------------------

fn store(comptime bpp: u32, p: [*]u8, color: u32) void {
    switch (bpp) {
        2 => @as(*align(1) volatile u16, @ptrCast(p)).* = @truncate(color),
        3 => {
            const v: [*]volatile u8 = @ptrCast(p);
            v[0] = @truncate(color);
            v[1] = @truncate(color >> 8);
            v[2] = @truncate(color >> 16);
        },
        4 => @as(*align(1) volatile u32, @ptrCast(p)).* = color,
        else => unreachable,
    }
}

/// Address of pixel (x, y).
fn at(raster: *const Raster, comptime bpp: u32, x: u32, y: u32) [*]u8 {
    return raster.base + (@as(usize, y) * raster.stride + @as(usize, x) * bpp);
}

/// Call `func(bpp, args...)` with the raster's pixel size as a comptime value.
fn dispatch(raster: *const Raster, comptime func: anytype, args: anytype) void {
    switch (bytesPerPixel(raster)) {
        2 => @call(.auto, func, .{2} ++ args),
        3 => @call(.auto, func, .{3} ++ args),
        4 => @call(.auto, func, .{4} ++ args),
        else => {},
    }
}

// -- Rectangles -----------------------------------------------------------------

fn fillRectT(comptime bpp: u32, raster: *const Raster, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    var cy: u32 = 0;
    while (cy < h) : (cy += 1) {
        var p: [*]u8 = at(raster, bpp, x, y + cy);
        var cx: u32 = 0;
        while (cx < w) : (cx += 1) {
            store(bpp, p, color);
            p += bpp;
        }
    }
}

/// Fill an axis-aligned rectangle with a solid colour, clipped to the raster.
pub fn fillRect(raster: *const Raster, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (x >= raster.width or y >= raster.height) {
        return;
    }
    const cw: u32 = @min(w, raster.width - x);
    const ch: u32 = @min(h, raster.height - y);
    dispatch(raster, fillRectT, .{ raster, x, y, cw, ch, color });
}

/// Fill the whole raster with a solid colour.
pub fn clear(raster: *const Raster, color: u32) void {
    fillRect(raster, 0, 0, raster.width, raster.height, color);
}

// -- Glyphs ---------------------------------------------------------------------

/// Characters drawn from geometry instead of the font. A cell's character
/// code is either a font code (0..255, Latin-1) or one of these.
pub const SPECIAL: u16 = 0x100;
/// Box drawing: SPECIAL | arms, where the arms are BOX_* bits.
pub const BOX_LEFT: u16 = 0x01;
pub const BOX_RIGHT: u16 = 0x02;
pub const BOX_UP: u16 = 0x04;
pub const BOX_DOWN: u16 = 0x08;
/// Block elements and shades.
pub const BLOCK_FULL: u16 = SPECIAL | 0x10;
pub const BLOCK_UPPER: u16 = SPECIAL | 0x11;
pub const BLOCK_LOWER: u16 = SPECIAL | 0x12;
pub const SHADE_LIGHT: u16 = SPECIAL | 0x13;
pub const SHADE_MEDIUM: u16 = SPECIAL | 0x14;
pub const SHADE_DARK: u16 = SPECIAL | 0x15;

/// Whether the special character `code` sets pixel (col, row) of a w x h cell.
fn specialPixel(code: u16, col: u32, row: u32, w: u32, h: u32) bool {
    const k: u16 = code & 0xff;
    if (k < 0x10) {
        // Box drawing: arms meet at the cell centre, one pixel wide.
        const mx: u32 = w / 2;
        const my: u32 = h / 2;
        if (row == my and ((k & BOX_LEFT != 0 and col <= mx) or (k & BOX_RIGHT != 0 and col >= mx))) {
            return true;
        }
        if (col == mx and ((k & BOX_UP != 0 and row <= my) or (k & BOX_DOWN != 0 and row >= my))) {
            return true;
        }
        return false;
    }
    return switch (code) {
        BLOCK_FULL => true,
        BLOCK_UPPER => row < h / 2,
        BLOCK_LOWER => row >= h / 2,
        SHADE_LIGHT => (row % 2 == 0) and ((col + row / 2) % 2 == 0),
        SHADE_MEDIUM => (col + row) % 2 == 0,
        SHADE_DARK => !((row % 2 == 0) and ((col + row / 2) % 2 == 0)),
        else => false,
    };
}

fn putcharT(
    comptime bpp: u32,
    raster: *const Raster,
    x0: u32,
    y0: u32,
    fg: u32,
    bg: u32,
    code: u16,
    font: *const wsfont.Font,
    underline: bool,
) void {
    // Font glyph, or '?' when the font does not cover the code.
    var bitmap: ?[]const u8 = null;
    if (code < SPECIAL) {
        bitmap = wsfont.glyph(font, @intCast(code)) orelse wsfont.glyph(font, '?');
    }
    const w: u32 = font.width;
    const h: u32 = font.height;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var p: [*]u8 = at(raster, bpp, x0, y0 + row);
        const ul: bool = underline and row == h - 1;
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            var on: bool = ul;
            if (!on) {
                if (bitmap) |b| {
                    const bits: u8 = b[row * font.stride + col / 8];
                    on = (bits & (@as(u8, 0x80) >> @intCast(col % 8))) != 0;
                } else if (code >= SPECIAL) {
                    on = specialPixel(code, col, row, w, h);
                }
            }
            store(bpp, p, if (on) fg else bg);
            p += bpp;
        }
    }
}

/// Draw character `code` in cell (cell_x, cell_y): every pixel of the cell is
/// written once, foreground or background, so no stale pixels remain.
pub fn putchar(
    raster: *const Raster,
    cell_x: u32,
    cell_y: u32,
    fg: u32,
    bg: u32,
    code: u16,
    font: *const wsfont.Font,
    underline: bool,
) void {
    const x0: u32 = cell_x * font.width;
    const y0: u32 = cell_y * font.height;
    if (x0 + font.width > raster.width or y0 + font.height > raster.height) {
        return;
    }
    dispatch(raster, putcharT, .{ raster, x0, y0, fg, bg, code, font, underline });
}

// -- Scrolling ------------------------------------------------------------------

/// Copy `h` pixel rows starting at `src_y` to `dst_y` (regions may overlap),
/// `width` pixels from the left edge. Rows are copied in the order that keeps
/// overlapping moves correct, eight bytes at a time where possible.
pub fn copyRows(raster: *const Raster, dst_y: u32, src_y: u32, h: u32) void {
    if (h == 0 or dst_y == src_y) {
        return;
    }
    const row_bytes: usize = @as(usize, raster.width) * bytesPerPixel(raster);
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        // Moving up: copy top-down. Moving down: copy bottom-up.
        const k: u32 = if (dst_y < src_y) i else h - 1 - i;
        const dst: [*]u8 = raster.base + @as(usize, dst_y + k) * raster.stride;
        const src: [*]const u8 = raster.base + @as(usize, src_y + k) * raster.stride;
        copyLine(dst, src, row_bytes);
    }
}

fn copyLine(dst: [*]u8, src: [*]const u8, len: usize) void {
    var n: usize = 0;
    if (@intFromPtr(dst) % 8 == 0 and @intFromPtr(src) % 8 == 0) {
        const d: [*]volatile u64 = @ptrCast(@alignCast(dst));
        const s: [*]const volatile u64 = @ptrCast(@alignCast(src));
        while (n + 8 <= len) : (n += 8) {
            d[n / 8] = s[n / 8];
        }
    }
    const db: [*]volatile u8 = @ptrCast(dst);
    const sb: [*]const volatile u8 = @ptrCast(src);
    while (n < len) : (n += 1) {
        db[n] = sb[n];
    }
}
