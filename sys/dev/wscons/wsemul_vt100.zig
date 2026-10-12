// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// VT100/ANSI terminal emulator.
//
// A reduced counterpart of NetBSD's sys/dev/wscons/wsemul_vt100.c and of
// FreeBSD's sys/teken (used by vt(4)): a byte-stream state machine (ground,
// ESC, CSI, OSC) that maintains a screen grid and a cursor, then paints the
// affected cells through the rcons layer. It understands the subset full-screen
// curses programs use: cursor addressing and movement, erase in line/display,
// insert/delete lines, SGR (reset and reverse), the alternate screen, saved
// cursors, and a scrolling region.

const cons: type = @import("../cons.zig");
const rcons: type = @import("wscons_raster.zig");

const MAX_ROWS: usize = 100;
const MAX_COLS: usize = 256;
const MAX_PARAMS: usize = 16;

const Cell: type = struct {
    ch: u8 = ' ',
    reverse: bool = false,
};

// Screen model.
var grid: [MAX_ROWS][MAX_COLS]Cell = undefined;
var cols: u32 = 0;
var rows: u32 = 0;
var cx: u32 = 0;
var cy: u32 = 0;
var saved_cx: u32 = 0;
var saved_cy: u32 = 0;
var cur_reverse: bool = false;
var cursor_visible: bool = true;
var scroll_top: u32 = 0;
var scroll_bot: u32 = 0;

// Escape parser.
const State: type = enum { ground, esc, csi, osc, osc_esc, charset };
var state: State = .ground;
var params: [MAX_PARAMS]u32 = undefined;
var nparams: usize = 0;
var have_digit: bool = false;
var csi_private: bool = false;

/// Initialise the emulator to the raster console's size.
pub fn init() void {
    const d = rcons.dims();
    cols = if (d.cols > MAX_COLS) MAX_COLS else d.cols;
    rows = if (d.rows > MAX_ROWS) MAX_ROWS else d.rows;
    scroll_top = 0;
    scroll_bot = if (rows == 0) 0 else rows - 1;
    cursor_visible = true;
    cur_reverse = false;
    clearGrid();
    rcons.blank();
    cx = 0;
    cy = 0;
    repaintAll();
}

/// The console descriptor: output bytes go through putc(); colour changes are
/// forwarded to the painter.
pub fn console() cons.Console {
    return .{ .putc = putc, .setfg = setForeground };
}

fn setForeground(r: u8, g: u8, b: u8) void {
    rcons.setForeground(r, g, b);
    repaintAll();
}

// -- grid helpers ------------------------------------------------------------

fn clearGrid() void {
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            grid[r][c] = .{};
        }
    }
}

fn repaintAll() void {
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            drawCell(r, c);
        }
    }
}

/// Paint one cell, inverting it when the cursor is there.
fn drawCell(r: u32, c: u32) void {
    const cell = grid[r][c];
    const rev = cell.reverse != (cursor_visible and r == cy and c == cx);
    rcons.paintCell(r, c, cell.ch, rev);
}

fn blankRow(r: u32) void {
    var c: u32 = 0;
    while (c < cols) : (c += 1) {
        grid[r][c] = .{};
    }
}

/// Move the cursor, repainting only the two affected cells.
fn moveTo(nr: u32, nc: u32) void {
    if (nr == cy and nc == cx) {
        return;
    }
    const oldr = cy;
    const oldc = cx;
    cy = nr;
    cx = nc;
    drawCell(oldr, oldc);
    drawCell(cy, cx);
}

// -- primitives --------------------------------------------------------------

fn putChar(ch: u8) void {
    if (rows == 0 or cols == 0) {
        return;
    }
    grid[cy][cx].ch = ch;
    grid[cy][cx].reverse = cur_reverse;
    drawCell(cy, cx);
    if (cx + 1 >= cols) {
        cx = 0;
        lineFeed();
    } else {
        moveTo(cy, cx + 1);
    }
}

fn lineFeed() void {
    if (cy >= scroll_bot) {
        scrollUp();
    } else {
        moveTo(cy + 1, cx);
    }
}

fn reverseIndex() void {
    if (cy <= scroll_top) {
        scrollDown();
    } else {
        moveTo(cy - 1, cx);
    }
}

fn scrollUp() void {
    var r: u32 = scroll_top;
    while (r < scroll_bot) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            grid[r][c] = grid[r + 1][c];
        }
    }
    blankRow(scroll_bot);
    r = scroll_top;
    while (r <= scroll_bot) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            drawCell(r, c);
        }
    }
}

fn scrollDown() void {
    var r: u32 = scroll_bot;
    while (r > scroll_top) : (r -= 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            grid[r][c] = grid[r - 1][c];
        }
    }
    blankRow(scroll_top);
    r = scroll_top;
    while (r <= scroll_bot) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            drawCell(r, c);
        }
    }
}

fn eraseRange(r: u32, c0: u32, c1: u32) void {
    var c: u32 = c0;
    while (c < c1 and c < cols) : (c += 1) {
        grid[r][c] = .{};
        drawCell(r, c);
    }
}

// -- escape parsing ----------------------------------------------------------

/// Emit one character into the emulator.
pub fn putc(ch: u8) void {
    switch (state) {
        .ground => ground(ch),
        .esc => esc(ch),
        .csi => csi(ch),
        .osc => oscInput(ch),
        .osc_esc => {
            // After ESC while in OSC: ST (ESC \) ends the string.
            state = if (ch == '\\') .ground else .osc;
        },
        .charset => state = .ground,
    }
}

fn oscInput(ch: u8) void {
    if (ch == 0x07) {
        state = .ground; // BEL ends an OSC string
    } else if (ch == 0x1b) {
        state = .osc_esc;
    }
}

fn ground(ch: u8) void {
    switch (ch) {
        0x1b => {
            state = .esc;
        },
        '\r' => moveTo(cy, 0),
        '\n' => lineFeed(),
        0x08 => {
            if (cx > 0) moveTo(cy, cx - 1);
        },
        '\t' => {
            const stop: u32 = (cx / 8 + 1) * 8;
            var n = cx;
            while (n < stop and n < cols) : (n += 1) {
                grid[cy][n] = .{};
            }
            const target = if (stop >= cols) cols - 1 else stop;
            moveTo(cy, target);
        },
        0x07 => {}, // bell
        else => {
            if (ch >= 0x20) {
                putChar(ch);
            }
        },
    }
}

fn esc(ch: u8) void {
    switch (ch) {
        '[' => {
            state = .csi;
            nparams = 0;
            have_digit = false;
            csi_private = false;
        },
        ']' => state = .osc,
        '(', ')', '*', '+' => state = .charset,
        '7' => {
            saved_cx = cx;
            saved_cy = cy;
            state = .ground;
        },
        '8' => {
            moveTo(saved_cy, saved_cx);
            state = .ground;
        },
        'D' => {
            lineFeed();
            state = .ground;
        },
        'M' => {
            reverseIndex();
            state = .ground;
        },
        'E' => {
            cx = 0;
            lineFeed();
            state = .ground;
        },
        'c' => {
            resetTerm();
            state = .ground;
        },
        else => state = .ground,
    }
}

fn csi(ch: u8) void {
    if (ch >= '0' and ch <= '9') {
        if (nparams == 0) nparams = 1;
        const idx = nparams - 1;
        if (idx < MAX_PARAMS) {
            if (!have_digit) {
                params[idx] = ch - '0';
                have_digit = true;
            } else {
                params[idx] = params[idx] * 10 + (ch - '0');
            }
        }
        return;
    }
    if (ch == ';') {
        if (nparams == 0) nparams = 1;
        if (nparams < MAX_PARAMS) {
            nparams += 1;
        }
        have_digit = false;
        return;
    }
    if (ch == '?') {
        csi_private = true;
        return;
    }
    dispatch(ch);
    state = .ground;
}

fn param(i: usize, default: u32) u32 {
    if (i >= nparams) {
        return default;
    }
    if (params[i] == 0) {
        return default;
    }
    return params[i];
}

fn lastParam() u32 {
    if (nparams == 0) {
        return 0;
    }
    return params[nparams - 1];
}

fn clearScreen() void {
    clearGrid();
    rcons.blank();
    cx = 0;
    cy = 0;
    repaintAll();
}

fn resetTerm() void {
    cur_reverse = false;
    saved_cx = 0;
    saved_cy = 0;
    scroll_top = 0;
    scroll_bot = if (rows == 0) 0 else rows - 1;
    cursor_visible = true;
    clearScreen();
}

fn dispatch(final: u8) void {
    switch (final) {
        'A' => moveTo(if (cy >= param(0, 1)) cy - param(0, 1) else 0, cx),
        'B' => {
            const n = param(0, 1);
            moveTo(if (cy + n >= rows) rows - 1 else cy + n, cx);
        },
        'C' => {
            const n = param(0, 1);
            moveTo(cy, if (cx + n >= cols) cols - 1 else cx + n);
        },
        'D' => moveTo(cy, if (cx >= param(0, 1)) cx - param(0, 1) else 0),
        'E' => {
            const n = param(0, 1);
            cx = 0;
            var i: u32 = 0;
            while (i < n) : (i += 1) lineFeed();
        },
        'F' => {
            const n = param(0, 1);
            cx = 0;
            var i: u32 = 0;
            while (i < n) : (i += 1) reverseIndex();
        },
        'G' => {
            const c = param(0, 1);
            moveTo(cy, if (c - 1 >= cols) cols - 1 else c - 1);
        },
        'd' => {
            const r = param(0, 1);
            moveTo(if (r - 1 >= rows) rows - 1 else r - 1, cx);
        },
        'H', 'f' => {
            const r = param(0, 1);
            const c = param(1, 1);
            moveTo(if (r - 1 >= rows) rows - 1 else r - 1, if (c - 1 >= cols) cols - 1 else c - 1);
        },
        'J' => eraseDisplay(lastParam()),
        'K' => eraseLine(lastParam()),
        'm' => setGraphics(),
        'L' => insertLines(param(0, 1)),
        'M' => deleteLines(param(0, 1)),
        'P' => deleteChars(param(0, 1)),
        'X' => eraseRange(cy, cx, cx + param(0, 1)),
        'r' => {
            const top = param(0, 1) - 1;
            const bot = param(1, rows) - 1;
            if (top < bot and bot < rows) {
                scroll_top = top;
                scroll_bot = bot;
                moveTo(0, 0);
            }
        },
        'h' => setMode(true),
        'l' => setMode(false),
        's' => {
            saved_cx = cx;
            saved_cy = cy;
        },
        'u' => moveTo(saved_cy, saved_cx),
        else => {},
    }
}

fn eraseDisplay(mode: u32) void {
    switch (mode) {
        0 => {
            eraseRange(cy, cx, cols);
            var r: u32 = cy + 1;
            while (r < rows) : (r += 1) eraseRange(r, 0, cols);
        },
        1 => {
            eraseRange(cy, 0, cx + 1);
            var r: u32 = 0;
            while (r < cy) : (r += 1) eraseRange(r, 0, cols);
        },
        else => {
            var r: u32 = 0;
            while (r < rows) : (r += 1) eraseRange(r, 0, cols);
        },
    }
}

fn eraseLine(mode: u32) void {
    switch (mode) {
        0 => eraseRange(cy, cx, cols),
        1 => eraseRange(cy, 0, cx + 1),
        else => eraseRange(cy, 0, cols),
    }
}

fn setGraphics() void {
    var i: usize = 0;
    if (nparams == 0) {
        cur_reverse = false;
        return;
    }
    while (i < nparams) : (i += 1) {
        switch (params[i]) {
            0 => cur_reverse = false,
            7 => cur_reverse = true,
            27 => cur_reverse = false,
            // Colours are accepted but not yet rendered (one console colour).
            else => {},
        }
    }
}

fn setMode(set: bool) void {
    var i: usize = 0;
    while (i < nparams) : (i += 1) {
        const p = params[i];
        if (csi_private and (p == 1049 or p == 47 or p == 1047)) {
            clearScreen(); // alternate screen: reset and clear
        } else if (csi_private and p == 25) {
            cursor_visible = set;
            drawCell(cy, cx);
        }
        // Other modes (application keys, bracketed paste, blink, autowrap) are
        // accepted and ignored.
    }
}

fn insertLines(n: u32) void {
    var count: u32 = n;
    while (count > 0) : (count -= 1) {
        var r: u32 = scroll_bot;
        while (r > cy) : (r -= 1) {
            var c: u32 = 0;
            while (c < cols) : (c += 1) {
                grid[r][c] = grid[r - 1][c];
            }
        }
        blankRow(cy);
    }
    var r: u32 = cy;
    while (r <= scroll_bot) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) drawCell(r, c);
    }
}

fn deleteLines(n: u32) void {
    var count: u32 = n;
    while (count > 0) : (count -= 1) {
        var r: u32 = cy;
        while (r < scroll_bot) : (r += 1) {
            var c: u32 = 0;
            while (c < cols) : (c += 1) {
                grid[r][c] = grid[r + 1][c];
            }
        }
        blankRow(scroll_bot);
    }
    var r: u32 = cy;
    while (r <= scroll_bot) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) drawCell(r, c);
    }
}

fn deleteChars(n: u32) void {
    var c: u32 = cx;
    while (c + n < cols) : (c += 1) {
        grid[cy][c] = grid[cy][c + n];
    }
    while (c < cols) : (c += 1) {
        grid[cy][c] = .{};
    }
    c = cx;
    while (c < cols) : (c += 1) drawCell(cy, c);
}
