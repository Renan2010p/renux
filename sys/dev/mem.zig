// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Memory devices: /dev/null and /dev/zero.
//
// This is the Zig counterpart of NetBSD's sys/dev/mem.c, reduced to the two
// "memory" character devices userland relies on: /dev/null discards writes and
// reads as end-of-file, /dev/zero reads as an endless stream of zero bytes.
// Both accept any write.

const conf: type = @import("../sys/conf.zig");
const errno: type = @import("../sys/errno.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const prf: type = @import("../kern/subr_prf.zig");

/// Major number of the memory devices.
pub const MEM_MAJOR: usize = 2;
/// Minor numbers (FreeBSD's mm device minors).
pub const NULL_MINOR: usize = 2;
pub const ZERO_MINOR: usize = 12;

fn memOpen(dev: u64, flags: i32) ?*anyopaque {
    _ = flags;
    return @ptrFromInt(dev);
}

fn memRead(ctx: ?*anyopaque, buf: []u8) isize {
    const dev: u64 = @intFromPtr(ctx.?);
    if (conf.minor(dev) == ZERO_MINOR) {
        for (buf) |*b| {
            b.* = 0;
        }
        return @intCast(buf.len);
    }
    return 0; // /dev/null reads as end of file
}

fn memWrite(ctx: ?*anyopaque, buf: []const u8) isize {
    _ = ctx;
    return @intCast(buf.len); // discarded
}

fn memIoctl(ctx: ?*anyopaque, cmd: u64, arg: u64) i32 {
    _ = ctx;
    _ = cmd;
    _ = arg;
    return -errno.ENOTTY;
}

fn memClose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

const mem_cdevsw: conf.Cdevsw = .{
    .name = "mem",
    .d_type = conf.D_MEM,
    .open = memOpen,
    .read = memRead,
    .write = memWrite,
    .ioctl = memIoctl,
    .close = memClose,
};

fn memAttach(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(MEM_MAJOR, &mem_cdevsw);
    prf.log(prf.LOG_DEBUG, "mem: /dev/null, /dev/zero registered", .{});
}

comptime {
    sysinit.SYSINIT("sysinit_mem", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_FIRST, memAttach, null);
}
