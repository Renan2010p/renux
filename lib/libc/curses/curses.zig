// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// A minimal curses.
//
// Not a port of ncurses: a small subset built directly on ANSI escapes and the
// terminal line discipline, enough for a simple full-screen program. Output is
// written straight to the terminal (refresh is a no-op), and getch decodes the
// arrow keys.

const syscall: type = @import("../sys/syscall.zig");

pub export var LINES: c_int = 24;
pub export var COLS: c_int = 80;
pub export var stdscr: ?*anyopaque = null;

const A_NORMAL: c_int = 0;
const A_BOLD: c_int = 0x2000000;
pub const KEY_UP: c_int = 259;
pub const KEY_DOWN: c_int = 258;
pub const KEY_LEFT: c_int = 260;
pub const KEY_RIGHT: c_int = 261;
pub const OK: c_int = 0;
pub const ERR: c_int = -1;

var saved: syscall.Termios = undefined;
var inited: bool = false;
var keypad_on: bool = false;

fn writeStr(s: []const u8) void {
    _ = syscall.write(1, s);
}

fn writeInt(v: c_int) void {
    var buf: [12]u8 = undefined;
    var k: usize = 0;
    var x: c_int = v;
    if (x == 0) {
        buf[0] = '0';
        k = 1;
    }
    while (x > 0) {
        buf[k] = @intCast(@as(c_int, '0') + @rem(x, 10));
        k += 1;
        x = @divTrunc(x, 10);
    }
    var j: usize = k;
    while (j > 0) {
        j -= 1;
        _ = syscall.write(1, &.{buf[j]});
    }
}

fn setFlags(mask: u32) void {
    var t: syscall.Termios = saved;
    t.c_lflag &= ~mask;
    _ = syscall.ioctl(0, syscall.TIOCSETA, @intFromPtr(&t));
}

pub export fn initscr() ?*anyopaque {
    if (!inited) {
        _ = syscall.ioctl(0, syscall.TIOCGETA, @intFromPtr(&saved));
        inited = true;
    }
    // cbreak + noecho by default, like curses.
    setFlags(syscall.ICANON | syscall.ECHO);
    writeStr("\x1b[H\x1b[2J");
    return null;
}

pub export fn endwin() c_int {
    writeStr("\x1b[H\x1b[2J");
    if (inited) {
        _ = syscall.ioctl(0, syscall.TIOCSETA, @intFromPtr(&saved));
    }
    return OK;
}

pub export fn move(y: c_int, x: c_int) c_int {
    writeStr("\x1b[");
    writeInt(y + 1);
    writeStr(";");
    writeInt(x + 1);
    writeStr("H");
    return OK;
}

pub export fn addch(c: c_int) c_int {
    _ = syscall.write(1, &.{@intCast(c & 0xff)});
    return OK;
}

pub export fn addstr(s: [*:0]const u8) c_int {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    _ = syscall.write(1, s[0..n]);
    return OK;
}

pub export fn mvaddstr(y: c_int, x: c_int, s: [*:0]const u8) c_int {
    _ = move(y, x);
    return addstr(s);
}

pub export fn clear() c_int {
    writeStr("\x1b[H\x1b[2J");
    return OK;
}

pub export fn erase() c_int {
    return clear();
}

pub export fn clrtoeol() c_int {
    writeStr("\x1b[K");
    return OK;
}

pub export fn refresh() c_int {
    return OK;
}

pub export fn wrefresh(w: ?*anyopaque) c_int {
    _ = w;
    return OK;
}

pub export fn attrset(a: c_int) c_int {
    if ((a & A_BOLD) != 0) {
        writeStr("\x1b[1m");
    } else {
        writeStr("\x1b[0m");
    }
    return OK;
}

pub export fn attron(a: c_int) c_int {
    return attrset(a);
}

pub export fn attroff(a: c_int) c_int {
    _ = a;
    return attrset(A_NORMAL);
}

pub export fn keypad(w: ?*anyopaque, on: c_int) c_int {
    _ = w;
    keypad_on = on != 0;
    return OK;
}

fn readByte() ?u8 {
    var b: [1]u8 = undefined;
    const r: i64 = @bitCast(syscall.read(0, b[0..]));
    if (r != 1) {
        return null;
    }
    return b[0];
}

pub export fn getch() c_int {
    const c: ?u8 = readByte() orelse return ERR;
    if (keypad_on and c.? == 0x1b) {
        const b1: ?u8 = readByte() orelse return c.?;
        if (b1.? == '[') {
            const b2: ?u8 = readByte() orelse return c.?;
            return switch (b2.?) {
                'A' => KEY_UP,
                'B' => KEY_DOWN,
                'C' => KEY_RIGHT,
                'D' => KEY_LEFT,
                else => b2.?,
            };
        }
        return b1.?;
    }
    return c.?;
}

pub export fn noecho() c_int {
    setFlags(syscall.ECHO);
    return OK;
}

pub export fn echo() c_int {
    var t: syscall.Termios = saved;
    t.c_lflag |= syscall.ECHO;
    _ = syscall.ioctl(0, syscall.TIOCSETA, @intFromPtr(&t));
    return OK;
}

pub export fn cbreak() c_int {
    setFlags(syscall.ICANON);
    return OK;
}

pub export fn nocbreak() c_int {
    var t: syscall.Termios = saved;
    t.c_lflag |= syscall.ICANON;
    _ = syscall.ioctl(0, syscall.TIOCSETA, @intFromPtr(&t));
    return OK;
}

pub export fn nodelay(w: ?*anyopaque, flag: c_int) c_int {
    _ = w;
    _ = flag;
    return OK;
}

pub export fn endwin_ok() c_int {
    return OK;
}
