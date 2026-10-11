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
pub const SYS_fork: u64 = 2;
pub const SYS_read: u64 = 3;
pub const SYS_write: u64 = 4;
pub const SYS_open: u64 = 5;
pub const SYS_close: u64 = 6;
pub const SYS_wait4: u64 = 7;
pub const SYS_lseek: u64 = 19;
pub const SYS_getpid: u64 = 20;
pub const SYS_execve: u64 = 59;
pub const SYS_fstat: u64 = 62;

/// File status, matching the kernel's struct stat (sys/sys/stat.h).
pub const Stat: type = extern struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: u64,
    blksize: u64,
    blocks: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
};

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

/// Open `path`; returns a descriptor or a negative value.
pub fn open(path: [*:0]const u8, flags: u64, mode: u64) i64 {
    const r: u64 = syscall(SYS_open, .{ @intFromPtr(path), flags, mode, 0, 0, 0 });
    return @bitCast(r);
}

/// Close file descriptor `fd`.
pub fn close(fd: u64) i64 {
    const r: u64 = syscall(SYS_close, .{ fd, 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Reposition the offset of file descriptor `fd`.
pub fn lseek(fd: u64, off: i64, whence: u64) i64 {
    const r: u64 = syscall(SYS_lseek, .{ fd, @bitCast(off), whence, 0, 0, 0 });
    return @bitCast(r);
}

/// Fill in `st` for file descriptor `fd`.
pub fn fstat(fd: u64, st: *Stat) i64 {
    const r: u64 = syscall(SYS_fstat, .{ fd, @intFromPtr(st), 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Terminate the calling process.
pub fn exit(code: u64) noreturn {
    _ = syscall(SYS_exit, .{ code, 0, 0, 0, 0, 0 });
    unreachable;
}

/// Create a child process: returns 0 in the child, the child's pid in the
/// parent, or a negative value on error.
pub fn fork() i32 {
    const r: u64 = syscall(SYS_fork, .{ 0, 0, 0, 0, 0, 0 });
    return @bitCast(@as(u32, @truncate(r)));
}

/// Replace the process image with `path`, started with `argv`/`envp`. Returns
/// only on failure.
pub fn execve(path: [*:0]const u8, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) i64 {
    const r: u64 = syscall(SYS_execve, .{ @intFromPtr(path), @intFromPtr(argv), @intFromPtr(envp), 0, 0, 0 });
    return @bitCast(r);
}

/// Wait for a child to exit; returns its pid or a negative value.
pub fn wait(status: ?*i32) i32 {
    _ = status;
    const r: u64 = syscall(SYS_wait4, .{ 0, 0, 0, 0, 0, 0 });
    return @bitCast(@as(u32, @truncate(r)));
}

/// The calling process's pid.
pub fn getpid() i32 {
    const r: u64 = syscall(SYS_getpid, .{ 0, 0, 0, 0, 0, 0 });
    return @bitCast(@as(u32, @truncate(r)));
}
