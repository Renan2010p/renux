// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// 32 bits-per-pixel raster operations.
//
// This is the Zig counterpart of NetBSD's sys/dev/rasops/rasops32.c, limited to
// the depth the Limine framebuffer gives us. It draws solid rectangles and font
// glyphs and scrolls the framebuffer up by whole text rows.

const rasops: type = @import("rasops.zig");
const wsfont: type = @import("../wsfont/wsfont.zig");

/// Write one pixel.
fn putPixel(raster: *const rasops.Raster, x: u32, y: u32, color: u32) void {
    const offset: usize = @as(usize, y) * raster.stride + @as(usize, x) * 4;
    const px: *volatile u32 = @ptrFromInt(@intFromPtr(raster.base) + offset);
    px.* = color;
}

/// Fill an axis-aligned rectangle with a solid colour.
pub fn fillRect(raster: *const rasops.Raster, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    var cy: u32 = 0;
    while (cy < h) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < w) : (cx += 1) {
            putPixel(raster, x + cx, y + cy, color);
        }
    }
}

/// Fill the whole raster with a solid colour.
pub fn clear(raster: *const rasops.Raster, color: u32) void {
    fillRect(raster, 0, 0, raster.width, raster.height, color);
}

/// Draw one glyph at cell position (cell_x, cell_y), background then foreground.
pub fn putchar(
    raster: *const rasops.Raster,
    cell_x: u32,
    cell_y: u32,
    fg: u32,
    bg: u32,
    ch: u8,
    font: *const wsfont.Font,
) void {
    const bitmap = wsfont.glyph(font, ch) orelse return;
    const x0: u32 = cell_x * font.width;
    const y0: u32 = cell_y * font.height;

    var row: u32 = 0;
    while (row < font.height) : (row += 1) {
        // Paint the background for this row, then the set foreground bits.
        fillRect(raster, x0, y0 + row, font.width, 1, bg);
        const bits: u8 = bitmap[row * font.stride];
        var col: u8 = 0;
        while (col < font.width) : (col += 1) {
            const mask: u8 = @as(u8, 0x80) >> @intCast(col);
            if ((bits & mask) != 0) {
                putPixel(raster, x0 + col, y0 + row, fg);
            }
        }
    }
}

/// Scroll the raster up by `rows_px` pixel rows, clearing the freed rows.
pub fn scrollUp(raster: *const rasops.Raster, rows_px: u32, bg: u32) void {
    const from: usize = @as(usize, rows_px) * raster.stride;
    const total: usize = @as(usize, raster.height) * raster.stride;

    // Forward byte copy: the destination is below the source, so this is safe
    // with overlapping regions.
    var i: usize = 0;
    while (i < total - from) : (i += 1) {
        raster.base[i] = raster.base[from + i];
    }

    // Clear the last rows_px rows.
    const clear_start: u32 = raster.height - rows_px;
    fillRect(raster, 0, clear_start, raster.width, rows_px, bg);
}
