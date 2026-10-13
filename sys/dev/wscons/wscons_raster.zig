// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Raster console painter.
//
// This is the Zig counterpart of NetBSD's sys/dev/wscons/wscons_raster.h (the
// "rcons" layer) reduced to a painter: it owns the raster and the font and
// draws individual cells in the colours it is given. It keeps no screen
// contents and no cursor of its own; the terminal emulator (wsemul_vt100.zig)
// owns the screen grid and the cursor, exactly as NetBSD splits wsemul_* from
// rcons.
//
// While a program owns the display (KD_GRAPHICS, see sys/consio.zig) the
// painter is suspended and draws nothing; the emulator keeps updating its grid
// and repaints everything on resume.

const wsfont: type = @import("../wsfont/wsfont.zig");
const spleen8x16: type = @import("../wsfont/spleen8x16.zig");
const rasops: type = @import("../rasops/rasops.zig");

/// Raster console state.
pub const Rcons: type = struct {
    raster: rasops.Raster,
    font: *const wsfont.Font,
    cols: u32,
    rows: u32,
};

var rcons: Rcons = undefined;
var attached: bool = false;
var suspended: bool = false;

/// Attach a raster console to `framebuffer` using the default built-in font.
/// Returns false, attaching nothing, when the raster's pixel format cannot be
/// drawn on (the serial console still works).
pub fn attach(framebuffer: rasops.Raster) bool {
    return attachWithFont(framebuffer, &spleen8x16.font);
}

/// Attach a raster console using an explicit font.
pub fn attachWithFont(framebuffer: rasops.Raster, font: *const wsfont.Font) bool {
    if (!rasops.supported(&framebuffer)) {
        return false;
    }
    rcons = .{
        .raster = framebuffer,
        .font = font,
        .cols = rasops.cols(&framebuffer, font.width),
        .rows = rasops.rows(&framebuffer, font.height),
    };
    attached = true;
    rasops.clear(&rcons.raster, 0);
    return true;
}

/// True once a raster is attached.
pub fn isAttached() bool {
    return attached;
}

/// Screen size in character cells.
pub fn dims() struct { cols: u32, rows: u32 } {
    if (!attached) {
        return .{ .cols = 0, .rows = 0 };
    }
    return .{ .cols = rcons.cols, .rows = rcons.rows };
}

/// Stop (true) or resume (false) drawing, for KD_GRAPHICS / KD_TEXT.
pub fn setSuspended(s: bool) void {
    suspended = s;
}

/// True while drawing is suspended.
pub fn isSuspended() bool {
    return suspended;
}

fn active() bool {
    return attached and !suspended;
}

/// Fill the whole screen with the 0xRRGGBB colour `bg`.
pub fn blank(bg: u32) void {
    if (active()) {
        rasops.clear(&rcons.raster, rasops.pixelRgb(&rcons.raster, bg));
    }
}

/// Draw one cell: character `code` (see rasops.SPECIAL) in `fg` over `bg`,
/// both 0xRRGGBB, optionally underlined.
pub fn paintCell(row: u32, col: u32, code: u16, fg: u32, bg: u32, underline: bool) void {
    if (!active() or row >= rcons.rows or col >= rcons.cols) {
        return;
    }
    const r: *const rasops.Raster = &rcons.raster;
    rasops.putchar(r, col, row, rasops.pixelRgb(r, fg), rasops.pixelRgb(r, bg), code, rcons.font, underline);
}

/// Move `n` text rows from `src` to `dst` on the screen, for scrolling.
/// Returns false when nothing was copied (suspended or detached); the caller
/// must then repaint instead.
pub fn copyRows(dst: u32, src: u32, n: u32) bool {
    if (!active() or n == 0) {
        return false;
    }
    if (dst + n > rcons.rows or src + n > rcons.rows) {
        return false;
    }
    const h: u32 = rcons.font.height;
    rasops.copyRows(&rcons.raster, dst * h, src * h, n * h);
    return true;
}
