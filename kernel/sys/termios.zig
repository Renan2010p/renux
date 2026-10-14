// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Terminal attributes.
//
// This is the Zig counterpart of NetBSD's sys/sys/termios.h, reduced to the
// attributes and control characters the terminal line discipline uses. The
// flag values and the c_cc indices match NetBSD's.

/// Number of control characters.
pub const NCCS: usize = 20;

/// c_cc indices (NetBSD's V* order).
pub const VEOF: usize = 0;
pub const VEOL: usize = 1;
pub const VEOL2: usize = 2;
pub const VERASE: usize = 3;
pub const VWERASE: usize = 4;
pub const VKILL: usize = 5;
pub const VREPRINT: usize = 6;
pub const VINTR: usize = 7;
pub const VQUIT: usize = 8;
pub const VSUSP: usize = 9;
pub const VDSUSP: usize = 10;
pub const VSTART: usize = 11;
pub const VSTOP: usize = 12;
pub const VLNEXT: usize = 13;
pub const VDISCARD: usize = 14;
pub const VMIN: usize = 16;
pub const VTIME: usize = 17;

// Input flags (c_iflag).
pub const IGNBRK: u32 = 0x00000001;
pub const BRKINT: u32 = 0x00000002;
pub const IGNPAR: u32 = 0x00000004;
pub const INPCK: u32 = 0x00000010;
pub const ISTRIP: u32 = 0x00000020;
pub const INLCR: u32 = 0x00000040;
pub const IGNCR: u32 = 0x00000080;
pub const ICRNL: u32 = 0x00000100;
pub const IXON: u32 = 0x00000200;
pub const IXOFF: u32 = 0x00000400;

// Output flags (c_oflag).
pub const OPOST: u32 = 0x00000001;
pub const ONLCR: u32 = 0x00000002;
pub const OCRNL: u32 = 0x00000010;
pub const ONOCR: u32 = 0x00000020;
pub const ONLRET: u32 = 0x00000040;

// Control flags (c_cflag).
pub const CS8: u32 = 0x00000300;
pub const CREAD: u32 = 0x00000800;
pub const HUPCL: u32 = 0x00004000;
pub const CLOCAL: u32 = 0x00008000;

// Local flags (c_lflag).
pub const ECHOKE: u32 = 0x00000001;
pub const ECHOE: u32 = 0x00000002;
pub const ECHOK: u32 = 0x00000004;
pub const ECHO: u32 = 0x00000008;
pub const ECHONL: u32 = 0x00000010;
pub const ECHOCTL: u32 = 0x00000040;
pub const ISIG: u32 = 0x00000080;
pub const ICANON: u32 = 0x00000100;
pub const IEXTEN: u32 = 0x00000400;

/// Terminal attributes (NetBSD's struct termios). Declared extern so the
/// layout matches libc's copy.
pub const Termios: type = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_cc: [NCCS]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

/// Window size, for TIOCGWINSZ/TIOCSWINSZ.
pub const Winsize: type = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// The default attributes a terminal starts with.
pub fn defaults() Termios {
    var t: Termios = .{
        .c_iflag = ICRNL | IXON,
        .c_oflag = OPOST | ONLCR,
        .c_cflag = CS8 | CREAD | HUPCL | CLOCAL,
        .c_lflag = ECHOKE | ECHOE | ECHOK | ECHO | ECHOCTL | ISIG | ICANON | IEXTEN,
        .c_cc = undefined,
        .c_ispeed = 9600,
        .c_ospeed = 9600,
    };
    var i: usize = 0;
    while (i < NCCS) : (i += 1) {
        t.c_cc[i] = 0;
    }
    t.c_cc[VEOF] = 0x04; // ^D
    t.c_cc[VERASE] = 0x7f; // DEL
    t.c_cc[VKILL] = 0x15; // ^U
    t.c_cc[VINTR] = 0x03; // ^C
    t.c_cc[VQUIT] = 0x1c; // ^\
    t.c_cc[VSUSP] = 0x1a; // ^Z
    t.c_cc[VSTART] = 0x11; // ^Q
    t.c_cc[VSTOP] = 0x13; // ^S
    return t;
}
