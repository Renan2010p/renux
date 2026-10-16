// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Loader brand and logo.
//
// The counterpart of FreeBSD's stand/lua/gfx-*.lua: the brand (the system name
// in large letters, drawn above the menu) and the logo (drawn to its right).
// The art is Renux's own; FreeBSD's names and logos are trademarks of The
// FreeBSD Foundation and are not used. `loader_logo` selects the logo:
// "renux" (colour), "renuxbw" (monochrome) or "none".

const std: type = @import("std");
const platform: type = @import("platform");

/// Where the brand and the logo are drawn (column, row; from 1), as in
/// FreeBSD's drawer.lua.
const BRAND_X: usize = 2;
const BRAND_Y: usize = 1;
const LOGO_X: usize = 46;
const LOGO_Y: usize = 4;

/// The part of the logo that is the "R", drawn in white inside the cyan
/// ring: rows 2 to 6, columns 9 to 18 of the art.
const R_FIRST_ROW: usize = 2;
const R_LAST_ROW: usize = 6;
const R_FIRST_COL: usize = 9;
const R_END_COL: usize = 19;

/// The brand, drawn at (BRAND_X, BRAND_Y).
pub const brand: []const []const u8 = &.{
    " ____                      ",
    "|  _ \\ ___ _ __  _   ___  __",
    "| |_) / _ \\ '_ \\| | | \\ \\/ /",
    "|  _ <  __/ | | | |_| |>  < ",
    "|_| \\_\\___|_| |_|\\__,_/_/\\_\\",
};

/// The logo, drawn at (LOGO_X, LOGO_Y) where FreeBSD draws its orb: a ring
/// around an R.
pub const logo: []const []const u8 = &.{
    "        .--------.        ",
    "     .-'  ______  '-.     ",
    "   .'    |  __  \\    '.   ",
    "  /      | |__)  |     \\  ",
    " |       |  _   /       | ",
    " |       | | \\  \\       | ",
    "  \\      |_|  \\__\\     /  ",
    "   '.                .'   ",
    "     '-.          .-'     ",
    "        '--------'        ",
};

/// Draw the brand at its fixed position.
pub fn drawBrand() void {
    for (brand, 0..) |line, i| {
        platform.gotoxy(BRAND_X, BRAND_Y + i);
        platform.print(line);
    }
}

/// Draw the logo selected by `name` ("renux", "renuxbw" or "none").
pub fn drawLogo(name: []const u8, color: bool) void {
    if (std.mem.eql(u8, name, "none")) return;
    const colored: bool = color and !std.mem.eql(u8, name, "renuxbw");
    for (logo, 0..) |line, row| {
        platform.gotoxy(LOGO_X, LOGO_Y + row);
        if (colored) {
            drawColoredLogoLine(line, row);
        } else {
            platform.print(line);
        }
    }
}

/// Draw row `row` of the logo with the ring in cyan and the R in bright
/// white, printing each run of same-coloured characters at once.
fn drawColoredLogoLine(line: []const u8, row: usize) void {
    var run_start: usize = 0;
    var run_is_r: bool = false;
    for (0..line.len + 1) |col| {
        const at_end: bool = col == line.len;
        const is_r: bool = !at_end and isR(line, row, col);
        if (at_end or is_r != run_is_r) {
            if (col > run_start) {
                platform.setColor(if (run_is_r) .white else .cyan, true);
                platform.print(line[run_start..col]);
            }
            run_start = col;
            run_is_r = is_r;
        }
    }
    platform.resetColor();
}

/// True when the character at (`row`, `col`) of the logo belongs to the R.
fn isR(line: []const u8, row: usize, col: usize) bool {
    return row >= R_FIRST_ROW and row <= R_LAST_ROW and col >= R_FIRST_COL and col < R_END_COL and line[col] != ' ';
}
