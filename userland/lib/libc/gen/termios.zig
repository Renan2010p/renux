// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Terminal control.
//
// The Zig counterpart of NetBSD's lib/libc/gen/tcgetattr.c and friends: the
// C wrappers around the terminal ioctls.

const syscall: type = @import("../sys/syscall.zig");
const errno: type = @import("errno.zig");

/// The terminal attributes (`struct termios` in C).
pub const Termios: type = syscall.Termios;

pub export fn tcgetattr(fd: c_int, t: *Termios) c_int {
    if (syscall.ioctl(@intCast(fd), syscall.TIOCGETA, @intFromPtr(t)) != 0) {
        return errno.set(errno.ENOTTY);
    }
    return 0;
}

pub export fn tcsetattr(fd: c_int, action: c_int, t: *const Termios) c_int {
    _ = action;
    if (syscall.ioctl(@intCast(fd), syscall.TIOCSETA, @intFromPtr(t)) != 0) {
        return errno.set(errno.ENOTTY);
    }
    return 0;
}

pub export fn isatty(fd: c_int) c_int {
    var t: Termios = undefined;
    if (syscall.ioctl(@intCast(fd), syscall.TIOCGETA, @intFromPtr(&t)) != 0) {
        return 0;
    }
    return 1;
}
