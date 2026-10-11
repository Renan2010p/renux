// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Raster console.
//
// This is the Zig counterpart of NetBSD's sys/dev/wscons/wscons_rinit.c and
// wscons_raster.h (the "rcons" layer): a text console drawn onto a raster
// using a font, with a cursor, line wrapping and scrolling. It registers itself
// with the console switch so that kernel output (subr_prf) appears on screen.

const cons: type = @import("../cons.zig");
const wsfont: type = @import("../wsfont/wsfont.zig");
const spleen8x16: type = @import("../wsfont/spleen8x16.zig");
const rasops: type = @import("../rasops/rasops.zig");
const rasops32: type = @import("../rasops/rasops32.zig");

const TAB_WIDTH: u32 = 8;

/// Raster console state.
pub const Rcons: type = struct {
    raster: rasops.Raster,
    font: *const wsfont.Font,
    fg: u32,
    bg: u32,
    cols: u32,
    rows: u32,
    cx: u32,
    cy: u32,
};

var rcons: Rcons = undefined;

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
        .cx = 0,
        .cy = 0,
    };
    rasops32.clear(&rcons.raster, rcons.bg);
    drawCursor();
}

/// The console descriptor for this device, for cons.cn_attach().
pub fn console() cons.Console {
    return .{ .putc = putc, .setfg = setForeground };
}

/// Set the foreground colour (RGB), which the text and the block cursor use.
pub fn setForeground(r: u8, g: u8, b: u8) void {
    rcons.fg = rasops.pixel(&rcons.raster, r, g, b);
}

/// Draw the cursor as a filled block over the current cell, as the BSD
/// consoles do.
fn drawCursor() void {
    const cw: u32 = rcons.font.width;
    const ch: u32 = rcons.font.height;
    rasops32.fillRect(&rcons.raster, rcons.cx * cw, rcons.cy * ch, cw, ch, rcons.fg);
}

/// Erase the cursor block by repainting the cell in the background colour.
fn eraseCursor() void {
    const cw: u32 = rcons.font.width;
    const ch: u32 = rcons.font.height;
    rasops32.fillRect(&rcons.raster, rcons.cx * cw, rcons.cy * ch, cw, ch, rcons.bg);
}

/// Move to the next line, scrolling when the bottom is reached.
fn newline() void {
    eraseCursor();
    rcons.cx = 0;
    rcons.cy += 1;
    if (rcons.cy >= rcons.rows) {
        rcons.cy = rcons.rows - 1;
        rasops32.scrollUp(&rcons.raster, rcons.font.height, rcons.bg);
    }
    drawCursor();
}

/// Draw one glyph and advance the cursor, wrapping and scrolling as needed.
fn putGlyph(ch: u8) void {
    eraseCursor();
    rasops32.putchar(&rcons.raster, rcons.cx, rcons.cy, rcons.fg, rcons.bg, ch, rcons.font);
    rcons.cx += 1;
    if (rcons.cx >= rcons.cols) {
        rcons.cx = 0;
        rcons.cy += 1;
        if (rcons.cy >= rcons.rows) {
            rcons.cy = rcons.rows - 1;
            rasops32.scrollUp(&rcons.raster, rcons.font.height, rcons.bg);
        }
    }
    drawCursor();
}

/// Emit one character on the raster console.
pub fn putc(ch: u8) void {
    switch (ch) {
        '\n' => newline(),
        '\r' => {
            eraseCursor();
            rcons.cx = 0;
            drawCursor();
        },
        '\t' => {
            const stop: u32 = (rcons.cx / TAB_WIDTH + 1) * TAB_WIDTH;
            while (rcons.cx < stop and rcons.cx < rcons.cols) {
                putGlyph(' ');
            }
        },
        0x08 => {
            eraseCursor();
            if (rcons.cx > 0) {
                rcons.cx -= 1;
            } else if (rcons.cy > 0) {
                rcons.cy -= 1;
                rcons.cx = rcons.cols - 1;
            }
            drawCursor();
        },
        else => putGlyph(ch),
    }
}
