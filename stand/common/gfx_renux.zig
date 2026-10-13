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

const platform: type = @import("platform");

/// The brand, drawn at (2, 1) like FreeBSD's.
pub const brand: []const []const u8 = &.{
    " ____                      ",
    "|  _ \\ ___ _ __  _   ___  __",
    "| |_) / _ \\ '_ \\| | | \\ \\/ /",
    "|  _ <  __/ | | | |_| |>  < ",
    "|_| \\_\\___|_| |_|\\__,_/_/\\_\\",
};

/// The logo, drawn at (46, 4) like FreeBSD's orb: a ring around an R.
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
        platform.gotoxy(2, 1 + i);
        platform.print(line);
    }
}

/// Draw the logo selected by `name` ("renux", "renuxbw" or "none").
pub fn drawLogo(name: []const u8, color: bool) void {
    if (eql(name, "none")) return;
    const colored: bool = color and !eql(name, "renuxbw");
    for (logo, 0..) |line, i| {
        platform.gotoxy(46, 4 + i);
        if (!colored) {
            platform.print(line);
            continue;
        }
        // The ring in cyan, the R in bright white.
        var start: usize = 0;
        var in_r: bool = false;
        var k: usize = 0;
        while (k <= line.len) : (k += 1) {
            const now_r: bool = i >= 2 and i <= 6 and k < line.len and k >= 9 and k < 19 and line[k] != ' ';
            if (k == line.len or now_r != in_r) {
                if (k > start) {
                    if (in_r) platform.setColor(.white, true) else platform.setColor(.cyan, true);
                    platform.print(line[start..k]);
                }
                start = k;
                in_r = now_r;
            }
        }
        platform.resetColor();
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
