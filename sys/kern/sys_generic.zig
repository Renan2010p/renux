// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
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
const proc: type = @import("../sys/proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const subr_syscall: type = @import("subr_syscall.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const prf: type = @import("subr_prf.zig");

/// write(2): write to descriptor `fd`.
pub fn sysWrite(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
    if ((f.f_flag & file.FWRITE) == 0) {
        return sys.signed(-errno.EBADF);
    }
    const bytes: [*]u8 = @ptrFromInt(buf);
    const n: isize = f.f_ops.write(f, bytes[0..@intCast(count)]);
    if (n < 0) {
        return sys.signed(n);
    }
    return @intCast(n);
}

/// An I/O vector (FreeBSD's struct iovec).
const Iovec: type = extern struct {
    iov_base: u64,
    iov_len: u64,
};

/// writev(2): write the gathered buffers to `fd`.
pub fn sysWritev(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const iov_ptr: u64 = args[1];
    const iovcnt: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
    if ((f.f_flag & file.FWRITE) == 0) {
        return sys.signed(-errno.EBADF);
    }
    const iov: [*]align(1) const Iovec = @ptrFromInt(iov_ptr);
    var total: isize = 0;
    var i: u64 = 0;
    while (i < iovcnt) : (i += 1) {
        const len: u64 = iov[i].iov_len;
        if (len == 0) {
            continue;
        }
        const bytes: [*]u8 = @ptrFromInt(iov[i].iov_base);
        const n: isize = f.f_ops.write(f, bytes[0..@intCast(len)]);
        if (n < 0) {
            if (total > 0) {
                return @intCast(total);
            }
            return sys.signed(n);
        }
        total += n;
        if (n < len) {
            break;
        }
    }
    return @intCast(total);
}

/// readv(2): read into the gathered buffers from `fd`.
pub fn sysReadv(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const iov_ptr: u64 = args[1];
    const iovcnt: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
    if ((f.f_flag & file.FREAD) == 0) {
        return sys.signed(-errno.EBADF);
    }
    const iov: [*]align(1) const Iovec = @ptrFromInt(iov_ptr);
    var total: isize = 0;
    var i: u64 = 0;
    while (i < iovcnt) : (i += 1) {
        const len: u64 = iov[i].iov_len;
        if (len == 0) {
            continue;
        }
        const bytes: [*]u8 = @ptrFromInt(iov[i].iov_base);
        const n: isize = f.f_ops.read(f, bytes[0..@intCast(len)]);
        if (n < 0) {
            if (total > 0) {
                return @intCast(total);
            }
            return sys.signed(n);
        }
        total += n;
        if (n < len) {
            break;
        }
    }
    return @intCast(total);
}

/// pread(2): read at an explicit offset without moving the file position.
pub fn sysPread(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];
    const off: i64 = @bitCast(args[3]);

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
    if ((f.f_flag & file.FREAD) == 0) {
        return sys.signed(-errno.EBADF);
    }
    const saved: u64 = f.f_offset;
    f.f_offset = @intCast(off);
    const bytes: [*]u8 = @ptrFromInt(buf);
    const n: isize = f.f_ops.read(f, bytes[0..@intCast(count)]);
    f.f_offset = saved;
    if (n < 0) {
        return sys.signed(n);
    }
    return @intCast(n);
}

/// fcntl(2): implement the descriptor flags a C library probes. File status
/// flags are derived from the descriptor's read/write mode; everything else is
/// accepted and ignored.
pub fn sysFcntl(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const cmd: u64 = args[1];
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);

    // FreeBSD's sys/fcntl.h.
    const F_DUPFD: u64 = 0;
    const F_GETFD: u64 = 1;
    const F_SETFD: u64 = 2;
    const F_GETFL: u64 = 3;
    const F_SETFL: u64 = 4;
    const F_DUPFD_CLOEXEC: u64 = 17;
    const FD_CLOEXEC: u64 = 1;
    const p = kern_proc.current;
    switch (cmd) {
        F_DUPFD, F_DUPFD_CLOEXEC => {
            if (args[2] >= proc.NFILE) return sys.signed(-errno.EINVAL);
            return sys.signed(kern_descrip.fdDup(p, @intCast(fd), @intCast(args[2]), cmd == F_DUPFD_CLOEXEC));
        },
        F_GETFD => return if (p.fd_cloexec[@intCast(fd)]) FD_CLOEXEC else 0,
        F_SETFD => {
            kern_descrip.fdSetCloexec(p, @intCast(fd), (args[2] & FD_CLOEXEC) != 0);
            return 0;
        },
        F_GETFL => {
            const r: bool = (f.f_flag & file.FREAD) != 0;
            const w: bool = (f.f_flag & file.FWRITE) != 0;
            // O_RDONLY == 0, O_WRONLY == 1, O_RDWR == 2.
            const v: i64 = if (r and w) 2 else if (w) 1 else 0;
            return @intCast(v);
        },
        // Status flags (O_NONBLOCK, O_APPEND) are accepted; reads already
        // report EAGAIN to the generic layer, which blocks.
        F_SETFL => return 0,
        // Locks and the rest: there is one user of each file for now.
        else => return 0,
    }
}

/// read(2): read from descriptor `fd`.
pub fn sysRead(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
    if ((f.f_flag & file.FREAD) == 0) {
        return sys.signed(-errno.EBADF);
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
                return sys.signed(n);
            }
            return @intCast(n);
        }
        kern_sched.yield();
    }
}

/// klog(2): copy the kernel message buffer into `buf`; returns the length.
pub fn sysKlog(args: [sys.MAXARGS]u64) u64 {
    const buf: u64 = args[0];
    const len: u64 = args[1];
    if (buf == 0) {
        return sys.signed(-errno.EFAULT);
    }
    const dst: [*]u8 = @ptrFromInt(buf);
    const n: usize = prf.msgbufCopy(dst[0..@intCast(len)]);
    return @intCast(n);
}

/// ioctl(2): perform a control request on descriptor `fd`.
pub fn sysIoctl(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const cmd: u64 = args[1];
    const arg: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
    const ioctl = f.f_ops.ioctl orelse return sys.signed(-errno.ENOTTY);
    const err: i32 = ioctl(f, cmd, arg);
    if (err != 0) {
        return sys.signed(err);
    }
    return 0;
}

/// lseek(2): reposition the offset of descriptor `fd`.
pub fn sysLseek(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const off: i64 = @bitCast(args[1]);
    const whence: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.signed(-errno.EBADF);

    var base: i64 = 0;
    switch (whence) {
        0 => base = 0, // SEEK_SET
        1 => base = @intCast(f.f_offset), // SEEK_CUR
        2 => base = @intCast(subr_syscall.fileSize(f)), // SEEK_END
        else => return sys.signed(-errno.EINVAL),
    }
    const target: i64 = base + off;
    if (target < 0) {
        return sys.signed(-errno.EINVAL);
    }
    f.f_offset = @intCast(target);
    return @intCast(f.f_offset);
}
