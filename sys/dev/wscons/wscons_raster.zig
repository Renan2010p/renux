// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Raster console painter.
//
// This is the Zig counterpart of NetBSD's sys/dev/wscons/wscons_raster.h (the
// "rcons" layer) reduced to a painter: it owns the raster, the font and the
// colours, and draws individual cells. It keeps no screen contents and no
// cursor of its own; the terminal emulator (wsemul_vt100.zig) owns the screen
// grid and the cursor, exactly as NetBSD splits wsemul_* from rcons.

const wsfont: type = @import("../wsfont/wsfont.zig");
const spleen8x16: type = @import("../wsfont/spleen8x16.zig");
const rasops: type = @import("../rasops/rasops.zig");
const rasops32: type = @import("../rasops/rasops32.zig");

/// Raster console state.
pub const Rcons: type = struct {
    raster: rasops.Raster,
    font: *const wsfont.Font,
    fg: u32,
    bg: u32,
    cols: u32,
    rows: u32,
};

var rcons: Rcons = undefined;
var attached: bool = false;

/// Attach a raster console to `framebuffer` using the default built-in font.
pub fn attach(framebuffer: rasops.Raster) void {
    attachWithFont(framebuffer, &spleen8x16.font);
}

/// Attach a raster console using an explicit font.
pub fn attachWithFont(framebuffer: rasops.Raster, font: *const wsfont.Font) void {
    rcons = .{
        .raster = framebuffer,
        .font = font,
        .fg = rasops.pixel(&framebuffer, 0xff, 0xff, 0xff),
        .bg = rasops.pixel(&framebuffer, 0x00, 0x00, 0x00),
        .cols = rasops.cols(&framebuffer, font.width),
        .rows = rasops.rows(&framebuffer, font.height),
    };
    attached = true;
    rasops32.clear(&rcons.raster, rcons.bg);
}

/// True once a raster is attached.
pub fn isAttached() bool {
    return attached;
}

/// Screen size in character cells.
pub fn dims() struct { cols: u32, rows: u32 } {
    return .{ .cols = rcons.cols, .rows = rcons.rows };
}

/// Set the foreground colour (RGB) used for normal (non-reversed) text.
pub fn setForeground(r: u8, g: u8, b: u8) void {
    if (attached) {
        rcons.fg = rasops.pixel(&rcons.raster, r, g, b);
    }
}

/// Fill the whole screen with the background colour.
pub fn blank() void {
    rasops32.clear(&rcons.raster, rcons.bg);
}

/// Draw one cell: `ch` in the foreground over the background, swapping the two
/// when `reverse` (used for the cursor and for standout attributes).
pub fn paintCell(row: u32, col: u32, ch: u8, reverse: bool) void {
    if (!attached or row >= rcons.rows or col >= rcons.cols) {
        return;
    }
    var fg: u32 = rcons.fg;
    var bg: u32 = rcons.bg;
    if (reverse) {
        const t: u32 = fg;
        fg = bg;
        bg = t;
    }
    rasops32.putchar(&rcons.raster, col, row, fg, bg, ch, rcons.font);
}
