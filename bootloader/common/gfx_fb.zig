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
// It keeps a character grid, so the cursor (an underline bar) can be drawn and
// removed and the screen scrolled by repainting.

const font_module: type = @import("font");

/// The console font (kernel/dev/wsfont/spleen8x16.zig, shared with the
/// kernel console).
const font: *const @TypeOf(font_module.font) = &font_module.font;

/// The largest text grid kept (enough for 2560 x 2048 with an 8x16 font).
const MAX_COLS: usize = 320;
const MAX_ROWS: usize = 128;

/// The colour of text before any `setColor`: the VGA light grey.
const DEFAULT_FOREGROUND: u32 = 0xaaaaaa;
const BACKGROUND: u32 = 0x000000;

/// Bytes per pixel: the framebuffer is always 32-bit here.
const BYTES_PER_PIXEL: usize = 4;

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

/// One character cell of the grid: the character and its colour (0xRRGGBB).
const Cell: type = struct {
    ch: u21 = ' ',
    fg: u32 = DEFAULT_FOREGROUND,
};

var fb: Fb = undefined;
/// What is on the screen, so cells can be repainted (for the cursor and for
/// scrolling) without reading the framebuffer back.
var grid: [MAX_ROWS][MAX_COLS]Cell = undefined;
var ncols: usize = 0;
var nrows: usize = 0;
/// The cursor position, in cells.
var cx: usize = 0;
var cy: usize = 0;
/// The colour of text written from now on.
var fg_rgb: u32 = DEFAULT_FOREGROUND;
var cursor_on: bool = true;

/// Take over `f`: clear it and home the cursor.
pub fn init(f: Fb) void {
    fb = f;
    ncols = @min(f.width / font.width, MAX_COLS);
    nrows = @min(f.height / font.height, MAX_ROWS);
    clear();
}

/// The framebuffer pixel value for colour `rgb` (0xRRGGBB).
fn pixel(rgb: u32) u32 {
    const r: u32 = (rgb >> 16) & 0xff;
    const g: u32 = (rgb >> 8) & 0xff;
    const b: u32 = rgb & 0xff;
    return (r << fb.red_shift) | (g << fb.green_shift) | (b << fb.blue_shift);
}

// -- drawing -------------------------------------------------------------------

// Box-drawing characters are drawn by geometry rather than from the font
// (which has none): each is a set of "arms" running from the centre of the
// cell to the middle of its edges.
const ARM_LEFT: u4 = 1;
const ARM_RIGHT: u4 = 2;
const ARM_UP: u4 = 4;
const ARM_DOWN: u4 = 8;

/// Whether a box-drawing character with `arms` sets pixel (x, y) of its cell.
fn boxPixel(arms: u4, x: usize, y: usize) bool {
    const mid_x: usize = font.width / 2;
    const mid_y: usize = font.height / 2;
    if (y == mid_y and ((arms & ARM_LEFT != 0 and x <= mid_x) or (arms & ARM_RIGHT != 0 and x >= mid_x))) return true;
    if (x == mid_x and ((arms & ARM_UP != 0 and y <= mid_y) or (arms & ARM_DOWN != 0 and y >= mid_y))) return true;
    return false;
}

/// The arms of box-drawing character `ch` (single and double lines are drawn
/// alike), or null when it is not one.
fn boxArms(ch: u21) ?u4 {
    return switch (ch) {
        '─', '═' => ARM_LEFT | ARM_RIGHT,
        '│', '║' => ARM_UP | ARM_DOWN,
        '┌', '╔' => ARM_RIGHT | ARM_DOWN,
        '┐', '╗' => ARM_LEFT | ARM_DOWN,
        '└', '╚' => ARM_RIGHT | ARM_UP,
        '┘', '╝' => ARM_LEFT | ARM_UP,
        '├', '╠' => ARM_UP | ARM_DOWN | ARM_RIGHT,
        '┤', '╣' => ARM_UP | ARM_DOWN | ARM_LEFT,
        '┬', '╦' => ARM_LEFT | ARM_RIGHT | ARM_DOWN,
        '┴', '╩' => ARM_LEFT | ARM_RIGHT | ARM_UP,
        '┼', '╬' => ARM_LEFT | ARM_RIGHT | ARM_UP | ARM_DOWN,
        else => null,
    };
}

/// The font bitmap of `ch` (characters beyond Latin-1 show as '?'), or
/// null when the font has no glyph for it.
fn glyphFor(ch: u21) ?[]const u8 {
    const c: u21 = if (ch < 0x100) ch else '?';
    if (c < font.firstchar) return null;
    const index: usize = c - font.firstchar;
    if (index >= font.numchars) return null;
    const n: usize = @as(usize, font.height) * font.stride;
    return font.data[index * n ..][0..n];
}

/// Height in pixels of the cursor bar, as on the kernel console.
const CURSOR_ROWS: usize = 2;

/// Paint cell (col, row) from the grid; `cursor` adds the cursor bar along
/// the bottom of the cell.
fn paint(col: usize, row: usize, cursor: bool) void {
    const cell: Cell = grid[row][col];
    const fgp: u32 = pixel(cell.fg);
    const bgp: u32 = pixel(BACKGROUND);
    const arms: ?u4 = boxArms(cell.ch);
    const glyph: ?[]const u8 = if (arms == null) glyphFor(cell.ch) else null;
    var y: usize = 0;
    while (y < font.height) : (y += 1) {
        const line: [*]volatile u32 = @ptrCast(@alignCast(fb.base +
            (row * font.height + y) * fb.stride + col * font.width * BYTES_PER_PIXEL));
        var x: usize = 0;
        while (x < font.width) : (x += 1) {
            var on: bool = false;
            if (cursor and y + CURSOR_ROWS >= font.height) {
                on = true;
            } else if (arms) |a| {
                on = boxPixel(a, x, y);
            } else if (glyph) |g| {
                on = (g[y * font.stride + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8))) != 0;
            }
            line[x] = if (on) fgp else bgp;
        }
    }
}

/// Draw the cursor bar at the cursor position (if the cursor is shown).
fn drawCursor() void {
    if (cursor_on and cx < ncols and cy < nrows) paint(cx, cy, true);
}

/// Erase the cursor bar by repainting its cell.
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
    const black: u32 = pixel(BACKGROUND);
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

/// Move every line up by one, blank the last one and repaint the screen.
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

/// Move the cursor to the start of the next line, scrolling at the bottom.
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
