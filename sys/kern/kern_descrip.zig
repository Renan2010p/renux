// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// File descriptor table.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_descrip.c, reduced to
// the per-process table that maps a small integer to an open file (struct
// file): allocate a free slot, find a file by descriptor, and close it. File
// descriptors 0, 1 and 2 are handled specially by the read/write system calls
// and never live in this table.

const proc: type = @import("../sys/proc.zig");
const file: type = @import("../sys/file.zig");
const errno: type = @import("../sys/errno.zig");
const kmem: type = @import("subr_kmem.zig");

/// Build a new open-file entry. Its reference count starts at one.
pub fn newFile(f_type: u8, f_flag: i32, f_data: ?*anyopaque, f_ops: *const file.FileOps) ?*file.File {
    const f: *file.File = kmem.zallocAs(file.File) orelse return null;
    f.f_type = f_type;
    f.f_flag = f_flag;
    f.f_offset = 0;
    f.f_count = 1;
    f.f_data = f_data;
    f.f_ops = f_ops;
    return f;
}

/// Find a free descriptor at or above `start`, or null if the table is full.
pub fn fdalloc(p: *proc.Proc, start: usize) ?usize {
    var fd: usize = start;
    while (fd < proc.NFILE) : (fd += 1) {
        if (p.fds[fd] == null) {
            return fd;
        }
    }
    return null;
}

/// Place `f` in descriptor `fd`; a new descriptor is not close-on-exec.
pub fn fdAffix(p: *proc.Proc, fd: usize, f: *file.File) void {
    p.fds[fd] = f;
    p.fd_cloexec[fd] = false;
}

/// Set or clear FD_CLOEXEC on descriptor `fd`.
pub fn fdSetCloexec(p: *proc.Proc, fd: usize, on: bool) void {
    if (fd < proc.NFILE) {
        p.fd_cloexec[fd] = on;
    }
}

/// Duplicate descriptor `fd` onto the lowest free descriptor at or above
/// `start` (dup(2), fcntl F_DUPFD). Returns the new descriptor or -errno.
pub fn fdDup(p: *proc.Proc, fd: usize, start: usize, cloexec: bool) i64 {
    const f: *file.File = fdGetfile(p, fd) orelse return -@as(i64, errno.EBADF);
    const nfd: usize = fdalloc(p, start) orelse return -@as(i64, errno.EMFILE);
    f.f_count += 1;
    fdAffix(p, nfd, f);
    p.fd_cloexec[nfd] = cloexec;
    return @intCast(nfd);
}

/// Close the descriptors marked close-on-exec (at a successful execve).
pub fn fdCloseOnExec(p: *proc.Proc) void {
    var fd: usize = 0;
    while (fd < proc.NFILE) : (fd += 1) {
        if (p.fd_cloexec[fd] and p.fds[fd] != null) {
            _ = fd_close(p, fd);
        }
    }
}

/// The open file behind descriptor `fd`, or null.
pub fn fdGetfile(p: *proc.Proc, fd: usize) ?*file.File {
    if (fd >= proc.NFILE) {
        return null;
    }
    return p.fds[fd];
}

/// Drop one reference to `f`, closing and freeing it on the last one.
pub fn closeFile(f: *file.File) i32 {
    if (f.f_count > 0) {
        f.f_count -= 1;
    }
    if (f.f_count > 0) {
        return 0;
    }
    const err: i32 = f.f_ops.close(f);
    if (f.f_path) |path| kmem.free(@ptrCast(path));
    kmem.free(@ptrCast(f));
    return err;
}

/// Close descriptor `fd` of process `p`.
pub fn fd_close(p: *proc.Proc, fd: usize) i32 {
    if (fd >= proc.NFILE) {
        return errno.EBADF;
    }
    const f: *file.File = p.fds[fd] orelse return errno.EBADF;
    p.fds[fd] = null;
    p.fd_cloexec[fd] = false;
    return closeFile(f);
}

/// Close every descriptor of `p` (used when a process exits).
pub fn fd_closeAll(p: *proc.Proc) void {
    var fd: usize = 0;
    while (fd < proc.NFILE) : (fd += 1) {
        if (p.fds[fd]) |f| {
            p.fds[fd] = null;
            _ = closeFile(f);
        }
    }
}
