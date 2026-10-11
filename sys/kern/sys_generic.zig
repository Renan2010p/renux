// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Generic system calls.
//
// This is the Zig counterpart of NetBSD's sys/kern/sys_generic.c, reduced to
// the descriptor I/O calls read, write and lseek. read turns a device that has
// nothing ready (-EAGAIN) into a blocking wait that yields the CPU.

const sys: type = @import("../sys/syscall.zig");
const file: type = @import("../sys/file.zig");
const errno: type = @import("../sys/errno.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kern_sched: type = @import("kern_sched.zig");
const subr_syscall: type = @import("subr_syscall.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");

/// write(2): write to descriptor `fd`.
pub fn sysWrite(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;
    if ((f.f_flag & file.FWRITE) == 0) {
        return sys.ERROR;
    }
    const bytes: [*]u8 = @ptrFromInt(buf);
    const n: isize = f.f_ops.write(f, bytes[0..@intCast(count)]);
    if (n < 0) {
        return sys.ERROR;
    }
    return @intCast(n);
}

/// read(2): read from descriptor `fd`.
pub fn sysRead(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;
    if ((f.f_flag & file.FREAD) == 0) {
        return sys.ERROR;
    }
    const bytes: [*]u8 = @ptrFromInt(buf);
    const again: isize = -@as(isize, errno.EAGAIN);

    // A device with nothing ready returns -EAGAIN; block until it does,
    // yielding the CPU (with interrupts enabled) so the timer and other
    // processes keep running.
    while (true) {
        arch.cpu.enable_interrupts();
        const n: isize = f.f_ops.read(f, bytes[0..@intCast(count)]);
        arch.cpu.disable_interrupts();
        if (n != again) {
            if (n < 0) {
                return sys.ERROR;
            }
            return @intCast(n);
        }
        kern_sched.yield();
    }
}

/// lseek(2): reposition the offset of descriptor `fd`.
pub fn sysLseek(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const off: i64 = @bitCast(args[1]);
    const whence: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;

    var base: i64 = 0;
    switch (whence) {
        0 => base = 0, // SEEK_SET
        1 => base = @intCast(f.f_offset), // SEEK_CUR
        2 => base = @intCast(subr_syscall.fileSize(f)), // SEEK_END
        else => return sys.ERROR,
    }
    const target: i64 = base + off;
    if (target < 0) {
        return sys.ERROR;
    }
    f.f_offset = @intCast(target);
    return @intCast(f.f_offset);
}
