// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The /dev/tty character device.
//
// This is the Zig counterpart of the terminal half of NetBSD's sys/kern/
// tty_tty.c: a character device (major 1) that carries the console terminal
// and its line discipline, so programs that open /dev/tty get echo, line
// editing and (later) the signals the control characters generate.

const tty: type = @import("../kern/tty.zig");
const conf: type = @import("../sys/conf.zig");
const sysinit: type = @import("../sys/sysinit.zig");

/// Major number of the terminal device.
pub const TTY_MAJOR: usize = 1;

/// The single console terminal.
var the_tty: tty.Tty = undefined;
var have_tty: bool = false;

fn ttyOpen(dev: u64, flags: i32) ?*anyopaque {
    _ = dev;
    _ = flags;
    if (!have_tty) {
        tty.init(&the_tty);
        have_tty = true;
    }
    return &the_tty;
}

fn ttyRead(ctx: ?*anyopaque, buf: []u8) isize {
    const t: *tty.Tty = @ptrCast(@alignCast(ctx.?));
    return tty.read(t, buf);
}

fn ttyWrite(ctx: ?*anyopaque, buf: []const u8) isize {
    const t: *tty.Tty = @ptrCast(@alignCast(ctx.?));
    return tty.write(t, buf);
}

fn ttyIoctl(ctx: ?*anyopaque, cmd: u64, arg: u64) i32 {
    const t: *tty.Tty = @ptrCast(@alignCast(ctx.?));
    return tty.ioctl(t, cmd, arg);
}

fn ttyClose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

/// The terminal's character device switch.
const tty_cdevsw: conf.Cdevsw = .{
    .name = "tty",
    .open = ttyOpen,
    .read = ttyRead,
    .write = ttyWrite,
    .ioctl = ttyIoctl,
    .close = ttyClose,
};

fn ttyAttach(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(TTY_MAJOR, &tty_cdevsw);
}

comptime {
    sysinit.SYSINIT("sysinit_tty", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_SECOND, ttyAttach, null);
}
