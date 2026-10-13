// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Loader text console on a linear framebuffer.
//
// The counterpart of FreeBSD's stand/common/gfx_fb.c: once the firmware hands
// over a framebuffer, the loader draws its own text instead of using the
// firmware's text console, which only offers small modes drawn centred on the
// screen. The text grid covers the whole display from the top left corner,
// in the same Spleen 8x16 font the kernel console uses, so the hand-over from
// loader to kernel does not change the look of the screen.
//
// It keeps a character grid, so the cursor (a reversed cell) can be drawn and
// removed and the screen scrolled by repainting.

const font_mod: type = @import("font");

const font = &font_mod.font;

const MAX_COLS: usize = 320;
const MAX_ROWS: usize = 128;

/// A 32-bit linear framebuffer with 8-bit colour channels.
pub const Fb: type = struct {
    base: [*]u8,
    width: u32,
    height: u32,
    /// Bytes per scanline.
    stride: u32,
    red_shift: u5,
    green_shift: u5,
    blue_shift: u5,
};

const Cell: type = struct {
    ch: u21 = ' ',
    fg: u32 = 0xaaaaaa,
};

var fb: Fb = undefined;
var grid: [MAX_ROWS][MAX_COLS]Cell = undefined;
var ncols: usize = 0;
var nrows: usize = 0;
var cx: usize = 0;
var cy: usize = 0;
var fg_rgb: u32 = 0xaaaaaa;
var cursor_on: bool = true;

/// Take over `f`: clear it and home the cursor.
pub fn init(f: Fb) void {
    fb = f;
    ncols = @min(f.width / font.width, MAX_COLS);
    nrows = @min(f.height / font.height, MAX_ROWS);
    clear();
}

/// The text grid size.
pub fn cols() usize {
    return ncols;
}

pub fn rows() usize {
    return nrows;
}

fn pixel(rgb: u32) u32 {
    const r: u32 = (rgb >> 16) & 0xff;
    const g: u32 = (rgb >> 8) & 0xff;
    const b: u32 = rgb & 0xff;
    return (r << fb.red_shift) | (g << fb.green_shift) | (b << fb.blue_shift);
}

// -- drawing -------------------------------------------------------------------

/// Whether a box-drawing character sets pixel (x, y) of the cell: its arms
/// meet at the centre (left, right, up, down).
fn boxPixel(arms: u4, x: usize, y: usize) bool {
    const mx: usize = font.width / 2;
    const my: usize = font.height / 2;
    if (y == my and ((arms & 1 != 0 and x <= mx) or (arms & 2 != 0 and x >= mx))) return true;
    if (x == mx and ((arms & 4 != 0 and y <= my) or (arms & 8 != 0 and y >= my))) return true;
    return false;
}

/// Arms of the box-drawing characters the menu frame uses.
fn boxArms(ch: u21) ?u4 {
    return switch (ch) {
        0x2500, 0x2550 => 1 | 2, // ─ ═
        0x2502, 0x2551 => 4 | 8, // │ ║
        0x250c, 0x2554 => 2 | 8, // ┌ ╔
        0x2510, 0x2557 => 1 | 8, // ┐ ╗
        0x2514, 0x255a => 2 | 4, // └ ╚
        0x2518, 0x255d => 1 | 4, // ┘ ╝
        0x251c, 0x2560 => 4 | 8 | 2, // ├ ╠
        0x2524, 0x2563 => 4 | 8 | 1, // ┤ ╣
        0x252c, 0x2566 => 1 | 2 | 8, // ┬ ╦
        0x2534, 0x2569 => 1 | 2 | 4, // ┴ ╩
        0x253c, 0x256c => 1 | 2 | 4 | 8, // ┼ ╬
        else => null,
    };
}

fn glyphFor(ch: u21) ?[]const u8 {
    const c: u21 = if (ch < 0x100) ch else '?';
    if (c < font.firstchar) return null;
    const index: usize = c - font.firstchar;
    if (index >= font.numchars) return null;
    const n: usize = @as(usize, font.height) * font.stride;
    return font.data[index * n ..][0..n];
}

/// Paint cell (col, row) from the grid; `reverse` swaps the colours (the
/// cursor).
fn paint(col: usize, row: usize, reverse: bool) void {
    const cell: Cell = grid[row][col];
    var fgp: u32 = pixel(cell.fg);
    var bgp: u32 = pixel(0);
    if (reverse) {
        const t: u32 = fgp;
        fgp = bgp;
        bgp = t;
    }
    const arms: ?u4 = boxArms(cell.ch);
    const glyph: ?[]const u8 = if (arms == null) glyphFor(cell.ch) else null;
    var y: usize = 0;
    while (y < font.height) : (y += 1) {
        const line: [*]volatile u32 = @ptrCast(@alignCast(fb.base +
            (row * font.height + y) * fb.stride + col * font.width * 4));
        var x: usize = 0;
        while (x < font.width) : (x += 1) {
            var on: bool = false;
            if (arms) |a| {
                on = boxPixel(a, x, y);
            } else if (glyph) |g| {
                on = (g[y * font.stride + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8))) != 0;
            }
            line[x] = if (on) fgp else bgp;
        }
    }
}

fn drawCursor() void {
    if (cursor_on and cx < ncols and cy < nrows) paint(cx, cy, true);
}

fn hideCursor() void {
    if (cursor_on and cx < ncols and cy < nrows) paint(cx, cy, false);
}

// -- the console -----------------------------------------------------------------

/// Clear the screen and home the cursor.
pub fn clear() void {
    var r: usize = 0;
    while (r < nrows) : (r += 1) {
        var c: usize = 0;
        while (c < ncols) : (c += 1) grid[r][c] = .{ .ch = ' ', .fg = fg_rgb };
    }
    var y: usize = 0;
    const black: u32 = pixel(0);
    while (y < fb.height) : (y += 1) {
        const line: [*]volatile u32 = @ptrCast(@alignCast(fb.base + y * fb.stride));
        var x: usize = 0;
        while (x < fb.width) : (x += 1) line[x] = black;
    }
    cx = 0;
    cy = 0;
    drawCursor();
}

/// Set the colour of the text written from now on (0xRRGGBB).
pub fn setColor(rgb: u32) void {
    fg_rgb = rgb;
}

/// Move the cursor to column `x`, row `y` (from 0).
pub fn gotoxy(x: usize, y: usize) void {
    hideCursor();
    cx = @min(x, ncols -| 1);
    cy = @min(y, nrows -| 1);
    drawCursor();
}

/// Show or hide the cursor.
pub fn showCursor(on: bool) void {
    if (on == cursor_on) return;
    if (!on) hideCursor();
    cursor_on = on;
    if (on) drawCursor();
}

fn scroll() void {
    var r: usize = 1;
    while (r < nrows) : (r += 1) grid[r - 1] = grid[r];
    var c: usize = 0;
    while (c < ncols) : (c += 1) grid[nrows - 1][c] = .{ .ch = ' ', .fg = fg_rgb };
    r = 0;
    while (r < nrows) : (r += 1) {
        c = 0;
        while (c < ncols) : (c += 1) paint(c, r, false);
    }
}

fn newline() void {
    cx = 0;
    if (cy + 1 < nrows) {
        cy += 1;
    } else {
        scroll();
    }
}

/// Write one character (a Unicode code point), interpreting CR, LF and BS.
pub fn putc(ch: u21) void {
    if (ncols == 0) return;
    hideCursor();
    switch (ch) {
        '\r' => cx = 0,
        '\n' => newline(),
        0x08 => cx -|= 1,
        else => {
            if (cx >= ncols) newline();
            grid[cy][cx] = .{ .ch = ch, .fg = fg_rgb };
            paint(cx, cy, false);
            cx += 1;
        },
    }
    drawCursor();
}
