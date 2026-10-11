// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-independent system call numbers and wrappers.
//
// The Zig counterpart of NetBSD/FreeBSD lib/libc/sys: the portable wrappers a
// program calls (write, read, exit, ...). They forward to the architecture's
// primitive through lib/libc/arch, so nothing here names a register or an
// instruction.
//
// The numbers are shared with the kernel (sys/sys/syscall.zig); NetBSD and
// FreeBSD keep them in sys/sys/syscall.h, installed for both kernel and libc.

const arch: type = @import("../arch/arch.zig");

pub const SYS_exit: u64 = 1;
pub const SYS_read: u64 = 3;
pub const SYS_write: u64 = 4;

/// Issue a system call with up to six arguments.
pub fn syscall(number: u64, args: [6]u64) u64 {
    return arch.syscall.syscall(number, args[0], args[1], args[2], args[3], args[4], args[5]);
}

/// Write `buf` to file descriptor `fd`; returns the number of bytes written.
pub fn write(fd: u64, buf: []const u8) u64 {
    return syscall(SYS_write, .{ fd, @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

/// Read up to `buf.len` bytes from file descriptor `fd`.
pub fn read(fd: u64, buf: []u8) u64 {
    return syscall(SYS_read, .{ fd, @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

/// Terminate the calling process.
pub fn exit(code: u64) noreturn {
    _ = syscall(SYS_exit, .{ code, 0, 0, 0, 0, 0 });
    unreachable;
}
