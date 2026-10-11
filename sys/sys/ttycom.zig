// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Terminal ioctl requests.
//
// This is the Zig counterpart of NetBSD's sys/sys/ttycom.h, reduced to the
// requests the terminal layer answers. The numbers are built with the same
// _IOC encoding NetBSD uses, so they depend on the size of the argument
// structure.

const termios: type = @import("termios.zig");

// _IOC direction bits.
const IOC_OUT: u64 = 0x40000000;
const IOC_IN: u64 = 0x80000000;

/// Build an ioctl request number (NetBSD's _IOC macro).
fn ioc(dir: u64, group: u8, num: u8, len: usize) u64 {
    return dir | (@as(u64, len) << 16) | (@as(u64, group) << 8) | @as(u64, num);
}

/// Get terminal attributes (a struct termios).
pub const TIOCGETA: u64 = ioc(IOC_OUT, 't', 19, @sizeOf(termios.Termios));
/// Set terminal attributes (a struct termios).
pub const TIOCSETA: u64 = ioc(IOC_IN, 't', 20, @sizeOf(termios.Termios));
/// Get the window size (a struct winsize).
pub const TIOCGWINSZ: u64 = ioc(IOC_OUT, 't', 104, @sizeOf(termios.Winsize));
/// Set the window size (a struct winsize).
pub const TIOCSWINSZ: u64 = ioc(IOC_IN, 't', 103, @sizeOf(termios.Winsize));
