// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// VT100/xterm terminal emulator.
//
// A reduced counterpart of NetBSD's sys/dev/wscons/wsemul_vt100.c and of
// FreeBSD's sys/teken (used by vt(4)): a byte-stream state machine (ground,
// ESC, CSI, OSC) that maintains a screen grid and a cursor, then paints the
// affected cells through the rcons layer. It implements what TERM=xterm
// programs (shells, curses applications such as nano) rely on:
//
//   - cursor addressing and movement, erase in line/display, insert/delete of
//     lines and characters, scrolling regions, saved cursors, REP;
//   - SGR attributes: bold, underline, reverse, the 16 ANSI colours, the
//     256-colour palette and 24-bit colour, with erases in the current
//     background colour (xterm's "bce");
//   - deferred autowrap (a character in the last column wraps only when the
//     next one arrives), as every VT100-compatible terminal does;
//   - the alternate screen (?1049), which preserves the normal screen;
//   - UTF-8 input, shown through the font's Latin-1 glyphs, plus box-drawing
//     and block characters (Unicode and the DEC special graphics set) drawn
//     by rasops.
//
// Painting is incremental: the emulator remembers what each cell on the
// screen currently shows and only repaints cells whose appearance changed, and
// scrolling moves pixels instead of redrawing every glyph.

const cons: type = @import("../cons.zig");
const rcons: type = @import("wscons_raster.zig");
const rasops: type = @import("../rasops/rasops.zig");

const MAX_ROWS: usize = 100;
const MAX_COLS: usize = 256;
const MAX_PARAMS: usize = 16;
/// Largest value a CSI parameter accumulates to (avoids overflow on garbage).
const PARAM_MAX: u32 = 65535;

// Cell attributes.
const ATTR_REVERSE: u8 = 0x01;
const ATTR_UNDERLINE: u8 = 0x02;

/// One character cell: a character code (Latin-1 or rasops.SPECIAL), its
/// resolved colours (0xRRGGBB) and attributes.
const Cell: type = struct {
    ch: u16 = ' ',
    fg: u32 = 0xaaaaaa,
    bg: u32 = 0x000000,
    attr: u8 = 0,
};

/// What a cell on the screen currently shows, after reverse video and the
/// cursor are applied. Used to skip repainting unchanged cells.
const Painted: type = struct {
    ch: u16,
    fg: u32,
    bg: u32,
    /// Foreground pixel rows at the bottom of the cell: 0, 1 (underline) or
    /// CURSOR_ROWS (the cursor).
    underline: u8,

    const invalid: Painted = .{ .ch = 0xffff, .fg = 0, .bg = 0, .underline = 0 };

    fn eql(a: Painted, b: Painted) bool {
        return a.ch == b.ch and a.fg == b.fg and a.bg == b.bg and a.underline == b.underline;
    }
};

/// A colour as SGR selects it, resolved when a character is written.
const Color: type = union(enum) {
    default,
    index: u8,
    rgb: u32,
};

/// The graphic rendition applied to new characters.
const Pen: type = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

/// Cursor state saved by DECSC (ESC 7) and CSI s.
const Saved: type = struct {
    cx: u32 = 0,
    cy: u32 = 0,
    pen: Pen = .{},
    g0_dec: bool = false,
    g1_dec: bool = false,
    use_g1: bool = false,
};

// Screen model.
var grid: [MAX_ROWS][MAX_COLS]Cell = undefined;
var shown: [MAX_ROWS][MAX_COLS]Painted = undefined;
var cols: u32 = 0;
var rows: u32 = 0;
var cx: u32 = 0;
var cy: u32 = 0;
var pen: Pen = .{};
var saved: Saved = .{};
/// The last column was written; the next graphic character wraps first.
var wrap_pending: bool = false;
/// DECAWM: automatic wrap at the right margin.
var autowrap: bool = true;
/// DECCKM: the terminal wants application cursor keys (`\eOA`..`\eOD`).
var cursor_app: bool = false;
var cursor_visible: bool = true;
var scroll_top: u32 = 0;
var scroll_bot: u32 = 0;
/// Last graphic character written, repeated by REP (CSI n b).
var last_ch: u16 = ' ';

/// Colour of default-coloured text (changed by cons.cnSetColor, so kernel and
/// userland text can differ) and of the default background.
var default_fg: u32 = 0xffffff;
const default_bg: u32 = 0x000000;

// Character sets: G0/G1 may hold the DEC special graphics (line drawing) set.
var g0_dec: bool = false;
var g1_dec: bool = false;
var use_g1: bool = false;

// The normal screen, kept while the alternate screen is in use.
var alt_active: bool = false;
var main_grid: [MAX_ROWS][MAX_COLS]Cell = undefined;
var main_saved: Saved = .{};

// UTF-8 decoder.
var utf8_need: u8 = 0;
var utf8_cp: u32 = 0;

// Escape parser.
const State: type = enum { ground, esc, csi, osc, osc_esc, charset_g0, charset_g1, charset_other };
var state: State = .ground;
var params: [MAX_PARAMS]u32 = undefined;
var nparams: usize = 0;
var have_digit: bool = false;
/// The CSI began with '?' (a DEC private sequence).
var csi_private: bool = false;
/// The CSI began with '<', '=' or '>', or had an intermediate byte: a request
/// this emulator does not implement, ignored as a whole.
var csi_ignore: bool = false;

/// Initialise the emulator to the raster console's size.
pub fn init() void {
    const d = rcons.dims();
    cols = if (d.cols > MAX_COLS) MAX_COLS else d.cols;
    rows = if (d.rows > MAX_ROWS) MAX_ROWS else d.rows;
    resetState();
    clearGrid();
    invalidateShown();
    rcons.blank(default_bg);
    // The screen is now blank: record that, so only text gets painted.
    markShownBlank();
    drawCell(cy, cx);
}

/// The console descriptor: output bytes go through putc(); colour changes and
/// display-mode switches are handled here.
pub fn console() cons.Console {
    return .{
        .putc = putc,
        .setfg = setForeground,
        .size = size,
        .appCursor = appCursor,
        .setGraphics = setGraphics,
    };
}

/// True when DECCKM (application cursor keys) is set.
pub fn appCursor() bool {
    return cursor_app;
}

/// The console size in cells, for TIOCGWINSZ.
pub fn size() ?cons.Size {
    if (rows == 0 or cols == 0) {
        return null;
    }
    return .{ .rows = rows, .cols = cols };
}

/// Set the colour of default-coloured text written from now on. Text already
/// on the screen keeps its colour, so the kernel's messages stay distinct from
/// userland's.
fn setForeground(r: u8, g: u8, b: u8) void {
    default_fg = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// Leave the display to a graphical program (true) or take it back (false),
/// repainting the whole text screen.
fn setGraphics(graphics: bool) void {
    if (graphics == rcons.isSuspended()) {
        return;
    }
    rcons.setSuspended(graphics);
    if (!graphics) {
        invalidateShown();
        rcons.blank(default_bg);
        markShownBlank();
        repaintAll();
    }
}

// -- colours ---------------------------------------------------------------

/// The 16 ANSI colours, as FreeBSD's teken and VGA text mode show them.
const ansi: [16]u32 = .{
    0x000000, 0xaa0000, 0x00aa00, 0xaa5500, 0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa,
    0x555555, 0xff5555, 0x55ff55, 0xffff55, 0x5555ff, 0xff55ff, 0x55ffff, 0xffffff,
};

/// xterm's 256-colour palette: the 16 ANSI colours, a 6x6x6 cube, 24 greys.
fn palette(i: u8) u32 {
    if (i < 16) {
        return ansi[i];
    }
    if (i < 232) {
        const levels: [6]u32 = .{ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
        const n: u32 = i - 16;
        return (levels[n / 36] << 16) | (levels[(n / 6) % 6] << 8) | levels[n % 6];
    }
    const g: u32 = 8 + (@as(u32, i) - 232) * 10;
    return (g << 16) | (g << 8) | g;
}

fn resolveFg(p: Pen) u32 {
    return switch (p.fg) {
        // Bold default text is shown bright, as on the BSD consoles.
        .default => if (p.bold) 0xffffff else default_fg,
        .index => |i| palette(if (p.bold and i < 8) i + 8 else i),
        .rgb => |v| v,
    };
}

fn resolveBg(p: Pen) u32 {
    return switch (p.bg) {
        .default => default_bg,
        .index => |i| palette(i),
        .rgb => |v| v,
    };
}

/// An erased cell: a space in the default foreground over the current
/// background colour (background colour erase).
fn blankCell() Cell {
    return .{ .ch = ' ', .fg = default_fg, .bg = resolveBg(pen), .attr = 0 };
}

// -- painting --------------------------------------------------------------

fn invalidateShown() void {
    var r: usize = 0;
    while (r < MAX_ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < MAX_COLS) : (c += 1) {
            shown[r][c] = Painted.invalid;
        }
    }
}

/// Record that every cell shows a blank in the default background, after the
/// screen was cleared in one fill.
fn markShownBlank() void {
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            shown[r][c] = .{ .ch = ' ', .fg = default_bg, .bg = default_bg, .underline = 0 };
        }
    }
}

/// Height in pixels of the cursor: an underline bar, not a block.
const CURSOR_ROWS: u8 = 2;

/// How cell (r, c) should look now.
fn appearance(r: u32, c: u32) Painted {
    const cell: Cell = grid[r][c];
    const at_cursor: bool = cursor_visible and r == cy and c == cx;
    const reverse: bool = (cell.attr & ATTR_REVERSE) != 0;
    var p: Painted = .{
        .ch = cell.ch,
        .fg = if (reverse) cell.bg else cell.fg,
        .bg = if (reverse) cell.fg else cell.bg,
        .underline = if (at_cursor) CURSOR_ROWS else if ((cell.attr & ATTR_UNDERLINE) != 0) 1 else 0,
    };
    // A blank shows only its background; normalise the foreground so blanks
    // in different text colours compare equal and are not repainted.
    if (p.ch == ' ' and p.underline == 0) {
        p.fg = p.bg;
    }
    return p;
}

/// Paint cell (r, c) if its appearance changed.
fn drawCell(r: u32, c: u32) void {
    if (r >= rows or c >= cols) {
        return;
    }
    const p: Painted = appearance(r, c);
    if (Painted.eql(shown[r][c], p)) {
        return;
    }
    if (rcons.isSuspended()) {
        return; // repainted in full on resume
    }
    rcons.paintCell(r, c, p.ch, p.fg, p.bg, p.underline);
    shown[r][c] = p;
}

fn drawRows(top: u32, bot: u32) void {
    var r: u32 = top;
    while (r <= bot and r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            drawCell(r, c);
        }
    }
}

fn repaintAll() void {
    if (rows > 0) {
        drawRows(0, rows - 1);
    }
}

// -- grid helpers ------------------------------------------------------------

fn clearGrid() void {
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        blankRow(r);
    }
}

fn blankRow(r: u32) void {
    const b: Cell = blankCell();
    var c: u32 = 0;
    while (c < cols) : (c += 1) {
        grid[r][c] = b;
    }
}

/// Move the cursor, repainting only the two affected cells. Any explicit
/// cursor movement cancels a pending wrap.
fn moveTo(nr: u32, nc: u32) void {
    wrap_pending = false;
    const r: u32 = if (nr >= rows) rows -| 1 else nr;
    const c: u32 = if (nc >= cols) cols -| 1 else nc;
    if (r == cy and c == cx) {
        return;
    }
    const oldr: u32 = cy;
    const oldc: u32 = cx;
    cy = r;
    cx = c;
    drawCell(oldr, oldc);
    drawCell(cy, cx);
}

/// Scroll rows top..bot (inclusive) up by `n`, blanking the bottom `n` rows.
fn scrollUpRegion(top: u32, bot: u32, n_req: u32) void {
    if (top > bot or bot >= rows) {
        return;
    }
    const height: u32 = bot - top + 1;
    const n: u32 = @min(n_req, height);
    var r: u32 = top;
    while (r + n <= bot) : (r += 1) {
        grid[r] = grid[r + n];
    }
    while (r <= bot) : (r += 1) {
        blankRow(r);
    }
    // Move the pixels too, and what they show, so only new cells repaint.
    if (n < height and rcons.copyRows(top, top + n, height - n)) {
        r = top;
        while (r + n <= bot) : (r += 1) {
            shown[r] = shown[r + n];
        }
        while (r <= bot) : (r += 1) {
            invalidateRow(r);
        }
    }
    drawRows(top, bot);
}

/// Scroll rows top..bot (inclusive) down by `n`, blanking the top `n` rows.
fn scrollDownRegion(top: u32, bot: u32, n_req: u32) void {
    if (top > bot or bot >= rows) {
        return;
    }
    const height: u32 = bot - top + 1;
    const n: u32 = @min(n_req, height);
    var r: u32 = bot;
    while (r >= top + n) : (r -= 1) {
        grid[r] = grid[r - n];
        if (r == 0) break;
    }
    r = top;
    while (r < top + n) : (r += 1) {
        blankRow(r);
    }
    if (n < height and rcons.copyRows(top + n, top, height - n)) {
        r = bot;
        while (r >= top + n) : (r -= 1) {
            shown[r] = shown[r - n];
            if (r == 0) break;
        }
        r = top;
        while (r < top + n) : (r += 1) {
            invalidateRow(r);
        }
    }
    drawRows(top, bot);
}

fn invalidateRow(r: u32) void {
    var c: usize = 0;
    while (c < MAX_COLS) : (c += 1) {
        shown[r][c] = Painted.invalid;
    }
}

// -- primitives --------------------------------------------------------------

fn putChar(code: u16) void {
    if (rows == 0 or cols == 0) {
        return;
    }
    if (wrap_pending and autowrap) {
        moveTo(cy, 0);
        lineFeed();
    }
    var attr: u8 = 0;
    if (pen.reverse) attr |= ATTR_REVERSE;
    if (pen.underline) attr |= ATTR_UNDERLINE;
    grid[cy][cx] = .{ .ch = code, .fg = resolveFg(pen), .bg = resolveBg(pen), .attr = attr };
    last_ch = code;
    if (cx + 1 < cols) {
        moveTo(cy, cx + 1); // repaints the written cell and the cursor
    } else {
        // Last column: stay here and wrap when the next character arrives.
        drawCell(cy, cx);
        wrap_pending = true;
    }
}

fn lineFeed() void {
    if (cy == scroll_bot) {
        scrollUpRegion(scroll_top, scroll_bot, 1);
    } else if (cy + 1 < rows) {
        moveTo(cy + 1, cx);
    }
    wrap_pending = false;
}

fn reverseIndex() void {
    wrap_pending = false;
    if (cy == scroll_top) {
        scrollDownRegion(scroll_top, scroll_bot, 1);
    } else if (cy > 0) {
        moveTo(cy - 1, cx);
    }
}

fn eraseRange(r: u32, c0: u32, c1: u32) void {
    const b: Cell = blankCell();
    var c: u32 = c0;
    while (c < c1 and c < cols) : (c += 1) {
        grid[r][c] = b;
        drawCell(r, c);
    }
}

// -- character sets and UTF-8 ----------------------------------------------

const BOX_L: u16 = rasops.BOX_LEFT;
const BOX_R: u16 = rasops.BOX_RIGHT;
const BOX_U: u16 = rasops.BOX_UP;
const BOX_D: u16 = rasops.BOX_DOWN;

fn box(arms: u16) u16 {
    return rasops.SPECIAL | arms;
}

/// The DEC special graphics set (ESC ( 0), used by curses for line drawing.
fn decGraphics(ch: u8) u16 {
    return switch (ch) {
        'j' => box(BOX_L | BOX_U),
        'k' => box(BOX_L | BOX_D),
        'l' => box(BOX_R | BOX_D),
        'm' => box(BOX_R | BOX_U),
        'n' => box(BOX_L | BOX_R | BOX_U | BOX_D),
        'q', 'o', 'p', 'r', 's' => box(BOX_L | BOX_R),
        'x' => box(BOX_U | BOX_D),
        't' => box(BOX_U | BOX_D | BOX_R),
        'u' => box(BOX_U | BOX_D | BOX_L),
        'v' => box(BOX_L | BOX_R | BOX_U),
        'w' => box(BOX_L | BOX_R | BOX_D),
        'a' => rasops.SHADE_MEDIUM,
        '0' => rasops.BLOCK_FULL,
        '`' => '*', // diamond
        'f' => 0xb0, // degree
        'g' => 0xb1, // plus/minus
        '~' => 0xb7, // bullet
        'y' => '<', // less than or equal
        'z' => '>', // greater than or equal
        '{' => '*', // pi
        '|' => '!', // not equal
        '}' => 0xa3, // pound sterling
        else => ch,
    };
}

/// Map a Unicode code point to a cell code: Latin-1 straight to the font,
/// box-drawing and block characters to rasops' drawn shapes, a few common
/// typographic characters to ASCII, anything else to '?'. Returns null for
/// code points that occupy no cell (C1 controls).
fn mapCodepoint(cp: u32) ?u16 {
    if (cp < 0x80) return @intCast(cp);
    if (cp < 0xa0) return null;
    if (cp <= 0xff) return @intCast(cp);
    return switch (cp) {
        // Light, heavy and double box drawing, arm by arm.
        0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254c, 0x254d, 0x2550 => box(BOX_L | BOX_R),
        0x2502, 0x2503, 0x2506, 0x2507, 0x250a, 0x250b, 0x254e, 0x254f, 0x2551 => box(BOX_U | BOX_D),
        0x250c...0x250f, 0x2552...0x2554, 0x256d => box(BOX_R | BOX_D),
        0x2510...0x2513, 0x2555...0x2557, 0x256e => box(BOX_L | BOX_D),
        0x2514...0x2517, 0x2558...0x255a, 0x2570 => box(BOX_R | BOX_U),
        0x2518...0x251b, 0x255b...0x255d, 0x256f => box(BOX_L | BOX_U),
        0x251c...0x2523, 0x255e...0x2560 => box(BOX_U | BOX_D | BOX_R),
        0x2524...0x252b, 0x2561...0x2563 => box(BOX_U | BOX_D | BOX_L),
        0x252c...0x2533, 0x2564...0x2566 => box(BOX_L | BOX_R | BOX_D),
        0x2534...0x253b, 0x2567...0x2569 => box(BOX_L | BOX_R | BOX_U),
        0x253c...0x254b, 0x256a...0x256c => box(BOX_L | BOX_R | BOX_U | BOX_D),
        0x2574, 0x2578 => box(BOX_L),
        0x2575, 0x2579 => box(BOX_U),
        0x2576, 0x257a => box(BOX_R),
        0x2577, 0x257b => box(BOX_D),
        // Block elements and shades.
        0x2588 => rasops.BLOCK_FULL,
        0x2580 => rasops.BLOCK_UPPER,
        0x2584 => rasops.BLOCK_LOWER,
        0x2591 => rasops.SHADE_LIGHT,
        0x2592 => rasops.SHADE_MEDIUM,
        0x2593 => rasops.SHADE_DARK,
        // Typography.
        0x2010...0x2015, 0x2212 => '-',
        0x2018, 0x2019, 0x201a, 0x2032 => '\'',
        0x201c, 0x201d, 0x201e, 0x2033 => '"',
        0x2022, 0x2219, 0x22c5 => 0xb7,
        0x2026 => '.',
        0x2190 => '<',
        0x2192 => '>',
        0x2191 => '^',
        0x2193 => 'v',
        0x20ac => 'E', // euro sign
        else => '?',
    };
}

/// Feed one byte of a UTF-8 sequence (ch >= 0x80).
fn utf8Byte(ch: u8) void {
    if ((ch & 0xc0) == 0x80) {
        if (utf8_need == 0) {
            putChar('?'); // stray continuation byte
            return;
        }
        utf8_cp = (utf8_cp << 6) | (ch & 0x3f);
        utf8_need -= 1;
        if (utf8_need == 0) {
            if (mapCodepoint(utf8_cp)) |code| {
                putChar(code);
            }
        }
        return;
    }
    if (utf8_need != 0) {
        putChar('?'); // truncated sequence
    }
    if ((ch & 0xe0) == 0xc0) {
        utf8_need = 1;
        utf8_cp = ch & 0x1f;
    } else if ((ch & 0xf0) == 0xe0) {
        utf8_need = 2;
        utf8_cp = ch & 0x0f;
    } else if ((ch & 0xf8) == 0xf0) {
        utf8_need = 3;
        utf8_cp = ch & 0x07;
    } else {
        utf8_need = 0;
        putChar('?');
    }
}

// -- escape parsing ----------------------------------------------------------

/// Emit one character into the emulator.
pub fn putc(ch: u8) void {
    // CAN and SUB abort any sequence; ESC restarts one.
    if (ch == 0x18 or ch == 0x1a) {
        state = .ground;
        return;
    }
    switch (state) {
        .ground => ground(ch),
        .esc => esc(ch),
        .csi => csi(ch),
        .osc => oscInput(ch),
        .osc_esc => {
            // After ESC while in OSC: ST (ESC \) ends the string.
            state = if (ch == '\\') .ground else .osc;
        },
        .charset_g0 => {
            g0_dec = ch == '0';
            state = .ground;
        },
        .charset_g1 => {
            g1_dec = ch == '0';
            state = .ground;
        },
        .charset_other => state = .ground,
    }
}

fn oscInput(ch: u8) void {
    if (ch == 0x07) {
        state = .ground; // BEL ends an OSC string
    } else if (ch == 0x1b) {
        state = .osc_esc;
    }
}

/// Execute a C0 control character.
fn control(ch: u8) void {
    switch (ch) {
        0x1b => state = .esc,
        '\r' => moveTo(cy, 0),
        '\n', 0x0b, 0x0c => {
            // The kernel prints bare LF; treat it as CR+LF, as the BSD consoles
            // do (the tty has no ONLCR translation yet).
            moveTo(cy, 0);
            lineFeed();
        },
        0x08 => {
            if (cx > 0) moveTo(cy, cx - 1) else wrap_pending = false;
        },
        '\t' => {
            // Move to the next tab stop (every 8 columns); cells are untouched.
            const stop: u32 = (cx / 8 + 1) * 8;
            moveTo(cy, if (stop >= cols) cols -| 1 else stop);
        },
        0x0e => use_g1 = true, // SO: shift to G1
        0x0f => use_g1 = false, // SI: shift to G0
        else => {}, // BEL and the other controls
    }
}

fn ground(ch: u8) void {
    if (ch >= 0x80) {
        utf8Byte(ch);
        return;
    }
    if (utf8_need != 0) {
        utf8_need = 0;
        putChar('?'); // sequence cut short by an ASCII byte
    }
    if (ch < 0x20) {
        control(ch);
        return;
    }
    if (ch == 0x7f) {
        return; // DEL is ignored on output
    }
    const dec: bool = if (use_g1) g1_dec else g0_dec;
    putChar(if (dec) decGraphics(ch) else ch);
}

fn esc(ch: u8) void {
    state = .ground;
    switch (ch) {
        '[' => {
            state = .csi;
            nparams = 0;
            have_digit = false;
            csi_private = false;
            csi_ignore = false;
        },
        ']', 'P', '_', '^' => state = .osc, // OSC, DCS, APC, PM: skip to ST
        '(' => state = .charset_g0,
        ')' => state = .charset_g1,
        '*', '+', '#', '%', ' ' => state = .charset_other,
        '7' => saveCursor(),
        '8' => restoreCursor(),
        'D' => lineFeed(),
        'M' => reverseIndex(),
        'E' => {
            moveTo(cy, 0);
            lineFeed();
        },
        'c' => resetTerm(),
        0x1b => state = .esc,
        else => {}, // ESC = / ESC > (keypad modes) and others
    }
}

fn csi(ch: u8) void {
    switch (ch) {
        '0'...'9' => {
            if (nparams == 0) nparams = 1;
            const idx: usize = nparams - 1;
            if (idx < MAX_PARAMS) {
                const d: u32 = ch - '0';
                params[idx] = if (!have_digit) d else @min(params[idx] * 10 + d, PARAM_MAX);
                have_digit = true;
            }
        },
        ';', ':' => {
            if (nparams == 0) {
                nparams = 1;
                params[0] = 0;
            }
            if (nparams < MAX_PARAMS) {
                params[nparams] = 0;
                nparams += 1;
            }
            have_digit = false;
        },
        '?' => csi_private = true,
        '<', '=', '>' => csi_ignore = true,
        0x20...0x2f => csi_ignore = true, // intermediate bytes
        0x40...0x7e => {
            state = .ground;
            if (!have_digit and nparams > 0 and nparams <= MAX_PARAMS) {
                params[nparams - 1] = 0;
            }
            if (!csi_ignore) {
                dispatch(ch);
            }
        },
        0x1b => state = .esc,
        else => {
            if (ch < 0x20) control(ch); // controls execute inside a CSI
        },
    }
}

fn param(i: usize, default: u32) u32 {
    if (i >= nparams or i >= MAX_PARAMS) {
        return default;
    }
    if (params[i] == 0) {
        return default;
    }
    return params[i];
}

fn rawParam(i: usize) u32 {
    if (i >= nparams or i >= MAX_PARAMS) {
        return 0;
    }
    return params[i];
}

fn clearScreen() void {
    clearGrid();
    repaintAll();
}

fn resetState() void {
    pen = .{};
    saved = .{};
    scroll_top = 0;
    scroll_bot = rows -| 1;
    cursor_visible = true;
    cursor_app = false;
    autowrap = true;
    wrap_pending = false;
    g0_dec = false;
    g1_dec = false;
    use_g1 = false;
    utf8_need = 0;
    alt_active = false;
    cx = 0;
    cy = 0;
}

fn resetTerm() void {
    resetState();
    clearScreen();
    drawCell(cy, cx);
}

fn saveCursor() void {
    saved = .{ .cx = cx, .cy = cy, .pen = pen, .g0_dec = g0_dec, .g1_dec = g1_dec, .use_g1 = use_g1 };
}

fn restoreCursor() void {
    pen = saved.pen;
    g0_dec = saved.g0_dec;
    g1_dec = saved.g1_dec;
    use_g1 = saved.use_g1;
    moveTo(saved.cy, saved.cx);
}

fn dispatch(final: u8) void {
    if (csi_private) {
        switch (final) {
            'h' => setMode(true),
            'l' => setMode(false),
            else => {},
        }
        return;
    }
    switch (final) {
        'A' => moveTo(cy -| param(0, 1), cx),
        'B', 'e' => moveTo(cy + param(0, 1), cx),
        'C', 'a' => moveTo(cy, cx + param(0, 1)),
        'D' => moveTo(cy, cx -| param(0, 1)),
        'E' => moveTo(cy + param(0, 1), 0),
        'F' => moveTo(cy -| param(0, 1), 0),
        'G', '`' => moveTo(cy, param(0, 1) - 1),
        'd' => moveTo(param(0, 1) - 1, cx),
        'H', 'f' => moveTo(param(0, 1) - 1, param(1, 1) - 1),
        'J' => eraseDisplay(rawParam(0)),
        'K' => eraseLine(rawParam(0)),
        'm' => selectGraphicRendition(),
        'L' => if (cy >= scroll_top and cy <= scroll_bot) {
            scrollDownRegion(cy, scroll_bot, param(0, 1));
            moveTo(cy, 0);
        },
        'M' => if (cy >= scroll_top and cy <= scroll_bot) {
            scrollUpRegion(cy, scroll_bot, param(0, 1));
            moveTo(cy, 0);
        },
        'S' => scrollUpRegion(scroll_top, scroll_bot, param(0, 1)),
        'T' => scrollDownRegion(scroll_top, scroll_bot, param(0, 1)),
        'P' => deleteChars(param(0, 1)),
        'X' => eraseRange(cy, cx, cx + param(0, 1)),
        '@' => insertChars(param(0, 1)),
        'b' => {
            // REP: repeat the preceding graphic character n times (nano uses
            // this to fill its bars).
            var i: u32 = 0;
            const n: u32 = @min(param(0, 1), rows * cols);
            while (i < n) : (i += 1) putChar(last_ch);
        },
        'r' => {
            const top: u32 = param(0, 1) - 1;
            const bot: u32 = param(1, rows) - 1;
            if (top < bot and bot < rows) {
                scroll_top = top;
                scroll_bot = bot;
                moveTo(0, 0);
            }
        },
        's' => saveCursor(),
        'u' => restoreCursor(),
        else => {}, // h/l (ANSI modes), n (status reports), c (attributes), ...
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
        2, 3 => {
            var r: u32 = 0;
            while (r < rows) : (r += 1) eraseRange(r, 0, cols);
        },
        else => {},
    }
}

fn eraseLine(mode: u32) void {
    switch (mode) {
        0 => eraseRange(cy, cx, cols),
        1 => eraseRange(cy, 0, cx + 1),
        2 => eraseRange(cy, 0, cols),
        else => {},
    }
}

/// SGR: set the graphic rendition for new characters.
fn selectGraphicRendition() void {
    if (nparams == 0) {
        pen = .{};
        return;
    }
    var i: usize = 0;
    while (i < nparams and i < MAX_PARAMS) : (i += 1) {
        const p: u32 = params[i];
        switch (p) {
            0 => pen = .{},
            1 => pen.bold = true,
            4 => pen.underline = true,
            7 => pen.reverse = true,
            22 => pen.bold = false,
            24 => pen.underline = false,
            27 => pen.reverse = false,
            30...37 => pen.fg = .{ .index = @intCast(p - 30) },
            39 => pen.fg = .default,
            40...47 => pen.bg = .{ .index = @intCast(p - 40) },
            49 => pen.bg = .default,
            90...97 => pen.fg = .{ .index = @intCast(p - 90 + 8) },
            100...107 => pen.bg = .{ .index = @intCast(p - 100 + 8) },
            38, 48 => {
                // Extended colour: 38;5;n (palette) or 38;2;r;g;b (direct).
                var color: ?Color = null;
                if (rawParam(i + 1) == 5) {
                    color = .{ .index = @intCast(rawParam(i + 2) & 0xff) };
                    i += 2;
                } else if (rawParam(i + 1) == 2) {
                    const r: u32 = rawParam(i + 2) & 0xff;
                    const g: u32 = rawParam(i + 3) & 0xff;
                    const b: u32 = rawParam(i + 4) & 0xff;
                    color = .{ .rgb = (r << 16) | (g << 8) | b };
                    i += 4;
                }
                if (color) |c| {
                    if (p == 38) pen.fg = c else pen.bg = c;
                }
            },
            else => {}, // blink, italic, ... are accepted and not shown
        }
    }
}

fn setMode(set: bool) void {
    var i: usize = 0;
    while (i < nparams and i < MAX_PARAMS) : (i += 1) {
        switch (params[i]) {
            1 => cursor_app = set, // DECCKM
            7 => {
                autowrap = set; // DECAWM
                if (!set) wrap_pending = false;
            },
            25 => {
                cursor_visible = set; // DECTCEM
                drawCell(cy, cx);
            },
            47, 1047, 1049 => alternateScreen(set, params[i] == 1049),
            else => {}, // mouse, bracketed paste, blink, ... are ignored
        }
    }
}

/// Switch to (set) or from the alternate screen. The normal screen is kept
/// and comes back intact, as on xterm; ?1049 also saves and restores the
/// cursor.
fn alternateScreen(set: bool, with_cursor: bool) void {
    if (set == alt_active) {
        return;
    }
    if (set) {
        if (with_cursor) saveCursor();
        main_saved = saved;
        var r: u32 = 0;
        while (r < rows) : (r += 1) main_grid[r] = grid[r];
        alt_active = true;
        clearGrid();
        repaintAll();
    } else {
        var r: u32 = 0;
        while (r < rows) : (r += 1) grid[r] = main_grid[r];
        alt_active = false;
        saved = main_saved;
        if (with_cursor) restoreCursor();
        repaintAll();
    }
}

fn deleteChars(n_req: u32) void {
    const n: u32 = @min(n_req, cols - cx);
    var c: u32 = cx;
    while (c + n < cols) : (c += 1) {
        grid[cy][c] = grid[cy][c + n];
    }
    const b: Cell = blankCell();
    while (c < cols) : (c += 1) {
        grid[cy][c] = b;
    }
    wrap_pending = false;
    c = cx;
    while (c < cols) : (c += 1) drawCell(cy, c);
}

/// ICH: shift the line right by `n` cells from the cursor, blanking the gap.
fn insertChars(n_req: u32) void {
    const n: u32 = @min(n_req, cols - cx);
    var c: u32 = cols;
    while (c > cx + n) {
        c -= 1;
        grid[cy][c] = grid[cy][c - n];
    }
    const b: Cell = blankCell();
    var k: u32 = cx;
    while (k < cx + n) : (k += 1) {
        grid[cy][k] = b;
    }
    wrap_pending = false;
    c = cx;
    while (c < cols) : (c += 1) drawCell(cy, c);
}
