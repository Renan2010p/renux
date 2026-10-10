// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Raster operations: shared geometry and colour helpers.
//
// This is the Zig counterpart of NetBSD's sys/dev/rasops/rasops.h (and the
// depth-independent part of rasops.c). It describes a raster (a framebuffer)
// and knows how to turn an RGB triple into a pixel value for the framebuffer's
// colour masks. The per-depth drawing routines live in rasops32.zig.

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

/// Number of whole text columns that fit, given a font cell width.
pub fn cols(raster: *const Raster, cell_width: u8) u32 {
    return raster.width / cell_width;
}

/// Number of whole text rows that fit, given a font cell height.
pub fn rows(raster: *const Raster, cell_height: u8) u32 {
    return raster.height / cell_height;
}

/// Scale one 8-bit colour component into its position in a pixel.
fn channel(component: u8, mask_size: u8, mask_shift: u8) u32 {
    if (mask_size == 0) {
        return 0;
    }
    const scaled: u32 = @as(u32, component) >> @intCast(8 - mask_size);
    return scaled << @intCast(mask_shift);
}

/// Build a framebuffer pixel from an RGB triple.
pub fn pixel(raster: *const Raster, red: u8, green: u8, blue: u8) u32 {
    return channel(red, raster.red_mask_size, raster.red_mask_shift) |
        channel(green, raster.green_mask_size, raster.green_mask_shift) |
        channel(blue, raster.blue_mask_size, raster.blue_mask_shift);
}
