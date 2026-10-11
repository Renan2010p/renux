// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// The system console device.
//
// This is the Zig counterpart of the console device in NetBSD's sys/kern/
// (tty_cons.c) reduced to the character device that backs /dev/console: reads
// pull bytes from the console input queue and writes go to every attached
// console. A read returns -EAGAIN when nothing is ready; the read system call
// turns that into a blocking wait, so blocking is a property of read(2) rather
// than of every device.

const cons: type = @import("cons.zig");
const conf: type = @import("../sys/conf.zig");
const errno: type = @import("../sys/errno.zig");
const sysinit: type = @import("../sys/sysinit.zig");

/// Major number of the console device.
pub const CONSOLE_MAJOR: usize = 0;

fn consoleOpen(dev: u64, flags: i32) ?*anyopaque {
    _ = dev;
    _ = flags;
    return null;
}

fn consoleRead(ctx: ?*anyopaque, buf: []u8) isize {
    _ = ctx;
    if (buf.len == 0) {
        return 0;
    }
    const c: u8 = cons.cngetcPoll() orelse return -errno.EAGAIN;
    buf[0] = c;
    return 1;
}

fn consoleWrite(ctx: ?*anyopaque, buf: []const u8) isize {
    _ = ctx;
    for (buf) |c| {
        cons.cnputc(c);
    }
    return @intCast(buf.len);
}

fn consoleClose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

/// The console's character device switch.
const console_cdevsw: conf.Cdevsw = .{
    .name = "console",
    .open = consoleOpen,
    .read = consoleRead,
    .write = consoleWrite,
    .close = consoleClose,
};

fn consoleAttach(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(CONSOLE_MAJOR, &console_cdevsw);
}

comptime {
    sysinit.SYSINIT("sysinit_consoledev", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_FIRST, consoleAttach, null);
}
