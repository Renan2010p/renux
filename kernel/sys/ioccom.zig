// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ioctl request encoding.
//
// The Zig counterpart of FreeBSD's sys/sys/ioccom.h. A request number carries
// the transfer direction, the argument size, a group letter and a number:
//
//   bits 31..29  direction (IOC_IN, IOC_OUT, IOC_VOID)
//   bits 28..16  argument size in bytes
//   bits 15..8   group, e.g. 't' for terminals, 'F' for framebuffers
//   bits  7..0   number within the group
//
// The direction bits are FreeBSD's (IOC_OUT = 0x40000000, IOC_IN =
// 0x80000000), which are the reverse of Linux's; FreeBSD binaries depend on it.

pub const IOC_VOID: u64 = 0x20000000; // no parameters, or an int by value
pub const IOC_OUT: u64 = 0x40000000; // copy the parameter out to the caller
pub const IOC_IN: u64 = 0x80000000; // copy the parameter in from the caller
pub const IOC_INOUT: u64 = IOC_IN | IOC_OUT;

/// _IOC(): build a request number.
pub fn ioc(dir: u64, group: u8, num: u8, len: usize) u64 {
    return dir | (@as(u64, len & 0x1fff) << 16) | (@as(u64, group) << 8) | @as(u64, num);
}

/// _IO(): a request without a parameter.
pub fn io(group: u8, num: u8) u64 {
    return ioc(IOC_VOID, group, num, 0);
}

/// _IOR(): the kernel returns a `T`.
pub fn ior(group: u8, num: u8, comptime T: type) u64 {
    return ioc(IOC_OUT, group, num, @sizeOf(T));
}

/// _IOW(): the caller passes a `T`.
pub fn iow(group: u8, num: u8, comptime T: type) u64 {
    return ioc(IOC_IN, group, num, @sizeOf(T));
}

/// _IOWR(): a `T` is passed in and returned.
pub fn iowr(group: u8, num: u8, comptime T: type) u64 {
    return ioc(IOC_INOUT, group, num, @sizeOf(T));
}

/// _IOWINT(): an int passed by value as the ioctl argument.
pub fn iowint(group: u8, num: u8) u64 {
    return ioc(IOC_VOID, group, num, @sizeOf(c_int));
}

test "matches FreeBSD's encoding" {
    const std = @import("std");
    // TIOCGETA = _IOR('t', 19, struct termios), sizeof = 44 on amd64.
    try std.testing.expectEqual(@as(u64, 0x402c7413), ioc(IOC_OUT, 't', 19, 44));
    // KDSETMODE = _IOWINT('K', 10).
    try std.testing.expectEqual(@as(u64, 0x20044b0a), iowint('K', 10));
    // FBIOGTYPE = _IOR('F', 0, struct fbtype), 24 bytes.
    try std.testing.expectEqual(@as(u64, 0x40184600), ioc(IOC_OUT, 'F', 0, 24));
}
