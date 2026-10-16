// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Generic system calls.
//
// This is the Zig counterpart of FreeBSD's sys/kern/sys_generic.c: the
// descriptor I/O calls (read, write, their vector and positioned forms) and
// fcntl/ioctl.
//
// A file operation that cannot proceed yet (an empty pipe, a terminal with no
// input, a full pipe) returns -EAGAIN. As in FreeBSD, what the caller sees
// depends on the file's FNONBLOCK flag (O_NONBLOCK): with it, EAGAIN; without
// it, the process sleeps until something changes and the transfer is retried
// (see `transfer`).

const sys: type = @import("../sys/syscall.zig");
const file: type = @import("../sys/file.zig");
const errno: type = @import("../sys/errno.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const proc: type = @import("../sys/proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const subr_syscall: type = @import("subr_syscall.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const prf: type = @import("subr_prf.zig");

/// Run the file operation `op(f, request)` the way FreeBSD's dofileread and
/// dofilewrite do: when it reports "not ready yet" (-EAGAIN), a blocking
/// file (no FNONBLOCK) sleeps until there is I/O activity and retries, unless
/// a signal arrives (EINTR); a non-blocking file returns EAGAIN. Returns the
/// value for the system-call result register.
fn transfer(f: *file.File, request: anytype, comptime op: fn (*file.File, @TypeOf(request)) isize) u64 {
    const again: isize = -@as(isize, errno.EAGAIN);
    while (true) {
        arch.cpu.enable_interrupts();
        const n: isize = op(f, request);
        arch.cpu.disable_interrupts();
        if (n != again or (f.f_flag & file.FNONBLOCK) != 0) return sys.signed(n);
        if (kern_signal.interrupted(kern_proc.current)) return sys.signed(-errno.EINTR);
        kern_sched.ioWait();
    }
}

/// A user buffer: address and length.
const Buffer: type = struct { base: u64, len: u64 };

fn readBuffer(f: *file.File, b: Buffer) isize {
    const bytes: [*]u8 = @ptrFromInt(b.base);
    return f.f_ops.read(f, bytes[0..@intCast(b.len)]);
}

fn writeBuffer(f: *file.File, b: Buffer) isize {
    const bytes: [*]u8 = @ptrFromInt(b.base);
    return f.f_ops.write(f, bytes[0..@intCast(b.len)]);
}

/// write(2): `write(fd, buf, nbytes)`.
pub fn sysWrite(args: [sys.MAXARGS]u64) u64 {
    const f: *file.File = fileFor(args[0], file.FWRITE) orelse return sys.signed(-errno.EBADF);
    return transfer(f, Buffer{ .base = args[1], .len = args[2] }, writeBuffer);
}

/// An I/O vector (FreeBSD's struct iovec).
const Iovec: type = extern struct {
    iov_base: u64,
    iov_len: u64,
};

/// Write the `count` buffers of the iovec array at user address `iov_ptr` to
/// `f`, stopping at the first short write. Returns the bytes written, or a
/// negative errno when nothing was.
fn writeVector(f: *file.File, iov_ptr: u64, count: u64) isize {
    const iov: [*]align(1) const Iovec = @ptrFromInt(iov_ptr);
    var total: isize = 0;
    for (0..count) |i| {
        const len: u64 = iov[i].iov_len;
        if (len == 0) continue;
        const bytes: [*]u8 = @ptrFromInt(iov[i].iov_base);
        const n: isize = f.f_ops.write(f, bytes[0..@intCast(len)]);
        if (n < 0) return if (total > 0) total else n;
        total += n;
        if (n < len) break;
    }
    return total;
}

/// Read into the `count` buffers of the iovec array at user address
/// `iov_ptr` from `f`, stopping at the first short read. Returns the bytes
/// read, or a negative errno when nothing was.
fn readVector(f: *file.File, iov_ptr: u64, count: u64) isize {
    const iov: [*]align(1) const Iovec = @ptrFromInt(iov_ptr);
    var total: isize = 0;
    for (0..count) |i| {
        const len: u64 = iov[i].iov_len;
        if (len == 0) continue;
        const bytes: [*]u8 = @ptrFromInt(iov[i].iov_base);
        const n: isize = f.f_ops.read(f, bytes[0..@intCast(len)]);
        if (n < 0) return if (total > 0) total else n;
        total += n;
        if (n < len) break;
    }
    return total;
}

/// The open file behind `fd`, if it was opened with `mode` (FREAD/FWRITE).
fn fileFor(fd: u64, mode: i32) ?*file.File {
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return null;
    if ((f.f_flag & mode) == 0) return null;
    return f;
}

/// An iovec array in user memory: its address and element count.
const Vector: type = struct { iov: u64, count: u64 };

fn readVectorOp(f: *file.File, v: Vector) isize {
    return readVector(f, v.iov, v.count);
}

fn writeVectorOp(f: *file.File, v: Vector) isize {
    return writeVector(f, v.iov, v.count);
}

/// writev(2): `writev(fd, iov, iovcnt)`, write the gathered buffers.
pub fn sysWritev(args: [sys.MAXARGS]u64) u64 {
    const f: *file.File = fileFor(args[0], file.FWRITE) orelse return sys.signed(-errno.EBADF);
    return transfer(f, Vector{ .iov = args[1], .count = args[2] }, writeVectorOp);
}

/// readv(2): `readv(fd, iov, iovcnt)`, read into the gathered buffers.
pub fn sysReadv(args: [sys.MAXARGS]u64) u64 {
    const f: *file.File = fileFor(args[0], file.FREAD) orelse return sys.signed(-errno.EBADF);
    return transfer(f, Vector{ .iov = args[1], .count = args[2] }, readVectorOp);
}

/// Run `op(f, request)` at file position `offset` without moving the
/// file's own position (the p* calls: pread, pwrite, preadv, pwritev). As in
/// FreeBSD, a negative offset is EINVAL and a file without positions (a
/// pipe, a device) is ESPIPE.
fn positioned(fd: u64, mode: i32, offset_arg: u64, request: anytype, comptime op: fn (*file.File, @TypeOf(request)) isize) u64 {
    const offset: i64 = @bitCast(offset_arg);
    if (offset < 0) return sys.signed(-errno.EINVAL);
    const f: *file.File = fileFor(fd, mode) orelse return sys.signed(-errno.EBADF);
    if (f.f_type != file.DTYPE_VNODE) return sys.signed(-errno.ESPIPE);
    const saved: u64 = f.f_offset;
    f.f_offset = @intCast(offset);
    defer f.f_offset = saved;
    return transfer(f, request, op);
}

/// pread(2): `pread(fd, buf, nbytes, offset)`.
pub fn sysPread(args: [sys.MAXARGS]u64) u64 {
    return positioned(args[0], file.FREAD, args[3], Buffer{ .base = args[1], .len = args[2] }, readBuffer);
}

/// pwrite(2): `pwrite(fd, buf, nbytes, offset)`.
pub fn sysPwrite(args: [sys.MAXARGS]u64) u64 {
    return positioned(args[0], file.FWRITE, args[3], Buffer{ .base = args[1], .len = args[2] }, writeBuffer);
}

/// preadv(2): `preadv(fd, iov, iovcnt, offset)`. std.Io reads files this
/// way.
pub fn sysPreadv(args: [sys.MAXARGS]u64) u64 {
    return positioned(args[0], file.FREAD, args[3], Vector{ .iov = args[1], .count = args[2] }, readVectorOp);
}

/// pwritev(2): `pwritev(fd, iov, iovcnt, offset)`.
pub fn sysPwritev(args: [sys.MAXARGS]u64) u64 {
    return positioned(args[0], file.FWRITE, args[3], Vector{ .iov = args[1], .count = args[2] }, writeVectorOp);
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
            return sys.signed(kern_descrip.fdDup(p, @intCast(fd), @intCast(args[2]), cmd == F_DUPFD_CLOEXEC));
        },
        F_GETFD => return if (kern_descrip.fdGetCloexec(p, @intCast(fd))) FD_CLOEXEC else 0,
        F_SETFD => {
            kern_descrip.fdSetCloexec(p, @intCast(fd), (args[2] & FD_CLOEXEC) != 0);
            return 0;
        },
        F_GETFL => {
            const r: bool = (f.f_flag & file.FREAD) != 0;
            const w: bool = (f.f_flag & file.FWRITE) != 0;
            // O_RDONLY == 0, O_WRONLY == 1, O_RDWR == 2; the status flags
            // keep their values (FNONBLOCK == O_NONBLOCK).
            const access: i64 = if (r and w) 2 else if (w) 1 else 0;
            return @intCast(access | (f.f_flag & file.FCNTLFLAGS));
        },
        // The status flags Renux implements (FCNTLFLAGS) take the new value;
        // others, such as O_APPEND, are accepted and ignored.
        F_SETFL => {
            const wanted: i32 = @truncate(@as(i64, @bitCast(args[2])));
            f.f_flag = (f.f_flag & ~file.FCNTLFLAGS) | (wanted & file.FCNTLFLAGS);
            return 0;
        },
        // Locks and the rest: there is one user of each file for now.
        else => return 0,
    }
}

/// read(2): `read(fd, buf, nbytes)`.
pub fn sysRead(args: [sys.MAXARGS]u64) u64 {
    const f: *file.File = fileFor(args[0], file.FREAD) orelse return sys.signed(-errno.EBADF);
    return transfer(f, Buffer{ .base = args[1], .len = args[2] }, readBuffer);
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
