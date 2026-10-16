// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// File descriptors.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_descrip.c: the operations on
// a process's descriptor table (sys/filedesc.zig) and on the open files
// (struct file) its entries point to.
//
// As in FreeBSD:
//
//   - a process may hold up to getmaxfd() descriptors: its RLIMIT_NOFILE,
//     capped by kern.maxfilesperproc (both sized from memory, subr_param.zig);
//   - the table starts with NDFILE entries and doubles when a descriptor
//     beyond it is needed (fdgrowtable);
//   - the whole system holds at most kern.maxfiles open files; past that,
//     opening one fails with ENFILE.

const std: type = @import("std");
const proc: type = @import("../sys/proc.zig");
const file: type = @import("../sys/file.zig");
const filedesc: type = @import("../sys/filedesc.zig");
const errno: type = @import("../sys/errno.zig");
const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");
const kmem: type = @import("subr_kmem.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const kern_lockf: type = @import("kern_lockf.zig");
const kern_resource: type = @import("kern_resource.zig");
const subr_param: type = @import("subr_param.zig");

const Entry: type = filedesc.Entry;

/// Open files in the whole system (FreeBSD's openfiles, sysctl
/// kern.openfiles).
pub var openfiles: u32 = 0;

// -- open files ----------------------------------------------------------------

/// Build a new open-file entry (FreeBSD's falloc_noinstall). Its reference
/// count starts at one. Returns null when kern.maxfiles files are already
/// open, or when memory runs out.
pub fn newFile(f_type: u8, f_flag: i32, f_data: ?*anyopaque, f_ops: *const file.FileOps) ?*file.File {
    if (openfiles >= subr_param.maxfiles) return null;
    const f: *file.File = kmem.zallocAs(file.File) orelse return null;
    openfiles += 1;
    f.f_type = f_type;
    f.f_flag = f_flag;
    f.f_offset = 0;
    f.f_count = 1;
    f.f_data = f_data;
    f.f_ops = f_ops;
    return f;
}

/// Drop one reference to `f`, closing and freeing it on the last one.
pub fn closeFile(f: *file.File) i32 {
    if (f.f_count > 0) {
        f.f_count -= 1;
    }
    if (f.f_count > 0) {
        return 0;
    }
    kern_lockf.release(f); // a flock(2) lock ends with its open file
    const err: i32 = f.f_ops.close(f);
    if (f.f_path) |path| kmem.free(@ptrCast(path));
    kmem.free(@ptrCast(f));
    openfiles -= 1;
    return err;
}

// -- the table -----------------------------------------------------------------

/// The most descriptors `p` may hold (FreeBSD's getmaxfd): its
/// RLIMIT_NOFILE, capped by kern.maxfilesperproc.
pub fn getmaxfd(p: *proc.Proc) usize {
    const limit: i64 = p.rlimits[kern_resource.RLIMIT_NOFILE].cur;
    const soft: usize = if (limit < 0) 0 else @intCast(@min(limit, std.math.maxInt(u32)));
    return @min(soft, subr_param.maxfilesperproc);
}

/// Allocate room for `n` zeroed entries: from kmem when it is small enough,
/// otherwise as whole, physically contiguous pages reached through the
/// direct map (kmem serves at most a page).
fn allocEntries(n: usize) ?[]Entry {
    const bytes: usize = n * @sizeOf(Entry);
    if (bytes + kmem.HEADER <= param.PAGE_SIZE) {
        const raw: *anyopaque = kmem.zalloc(bytes) orelse return null;
        const first: [*]Entry = @ptrCast(@alignCast(raw));
        @memset(first[0..n], .{});
        return first[0..n];
    }
    const pages: u64 = (bytes + param.PAGE_SIZE - 1) / param.PAGE_SIZE;
    const pa: vm_page.PAddr = vm_page.physallocContig(pages) orelse return null;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;
    const first: [*]Entry = @ptrFromInt(pa.int() + hhdm);
    @memset(first[0..n], .{});
    return first[0..n];
}

/// Give back entries from allocEntries.
fn freeEntries(entries: []Entry) void {
    const bytes: usize = entries.len * @sizeOf(Entry);
    if (bytes + kmem.HEADER <= param.PAGE_SIZE) {
        kmem.free(@ptrCast(entries.ptr));
        return;
    }
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
    const pages: u64 = (bytes + param.PAGE_SIZE - 1) / param.PAGE_SIZE;
    vm_page.physfreeContig(vm_page.PAddr.fromInt(@intFromPtr(entries.ptr) - hhdm), pages);
}

/// Grow `p`'s table to hold descriptor `fd` (FreeBSD's fdgrowtable_exp):
/// to twice its size, or more if `fd` needs it, but not past getmaxfd().
/// Returns false when `fd` is beyond the limit or memory runs out.
fn growTable(p: *proc.Proc, fd: usize) bool {
    const limit: usize = getmaxfd(p);
    if (fd >= limit) return false;
    const old: []Entry = p.fd.entries();
    if (fd < old.len) return true;
    const size: usize = @min(@max(old.len * 2, fd + 1), limit);
    const new: []Entry = allocEntries(size) orelse return false;
    @memcpy(new[0..old.len], old);
    if (p.fd.grown) |previous| freeEntries(previous);
    p.fd.grown = new;
    return true;
}

/// Find the lowest free descriptor at or above `start`, growing the table
/// when it is full (FreeBSD's fdalloc). Returns null when `p` holds as many
/// descriptors as it may.
pub fn fdalloc(p: *proc.Proc, start: usize) ?usize {
    const entries: []Entry = p.fd.entries();
    var fd: usize = start;
    while (fd < entries.len) : (fd += 1) {
        if (entries[fd].file == null) return fd;
    }
    if (!growTable(p, fd)) return null;
    return fd;
}

/// Make sure descriptor `fd` fits in `p`'s table, growing it if needed (for
/// dup2(2), which names its target). Returns false when `fd` is beyond the
/// process's limit or memory runs out.
pub fn fdReserve(p: *proc.Proc, fd: usize) bool {
    return growTable(p, fd);
}

/// Place `f` in descriptor `fd`, which fdalloc or fdReserve has made room
/// for; a new descriptor is not close-on-exec.
pub fn fdAffix(p: *proc.Proc, fd: usize, f: *file.File) void {
    const e: *Entry = p.fd.entry(fd) orelse unreachable; // the caller made room
    e.* = .{ .file = f, .cloexec = false };
}

/// Set or clear FD_CLOEXEC on descriptor `fd`.
pub fn fdSetCloexec(p: *proc.Proc, fd: usize, on: bool) void {
    if (p.fd.entry(fd)) |e| e.cloexec = on;
}

/// Whether descriptor `fd` is close-on-exec.
pub fn fdGetCloexec(p: *proc.Proc, fd: usize) bool {
    const e: *Entry = p.fd.entry(fd) orelse return false;
    return e.cloexec;
}

/// The open file behind descriptor `fd`, or null.
pub fn fdGetfile(p: *proc.Proc, fd: usize) ?*file.File {
    const e: *Entry = p.fd.entry(fd) orelse return null;
    return e.file;
}

/// Duplicate descriptor `fd` onto the lowest free descriptor at or above
/// `start` (dup(2), fcntl F_DUPFD). Returns the new descriptor or -errno.
pub fn fdDup(p: *proc.Proc, fd: usize, start: usize, cloexec: bool) i64 {
    const f: *file.File = fdGetfile(p, fd) orelse return -@as(i64, errno.EBADF);
    if (start >= getmaxfd(p)) return -@as(i64, errno.EINVAL);
    const nfd: usize = fdalloc(p, start) orelse return -@as(i64, errno.EMFILE);
    f.f_count += 1;
    fdAffix(p, nfd, f);
    fdSetCloexec(p, nfd, cloexec);
    return @intCast(nfd);
}

/// Close descriptor `fd` of process `p`.
pub fn fd_close(p: *proc.Proc, fd: usize) i32 {
    const e: *Entry = p.fd.entry(fd) orelse return errno.EBADF;
    const f: *file.File = e.file orelse return errno.EBADF;
    e.* = .{};
    return closeFile(f);
}

/// Close the descriptors marked close-on-exec (at a successful execve).
pub fn fdCloseOnExec(p: *proc.Proc) void {
    for (p.fd.entries(), 0..) |e, fd| {
        if (e.cloexec and e.file != null) _ = fd_close(p, fd);
    }
}

/// Close every descriptor of `p` and release a grown table (when the
/// process exits; FreeBSD's fdescfree).
pub fn fd_closeAll(p: *proc.Proc) void {
    for (p.fd.entries()) |*e| {
        if (e.file) |f| {
            e.* = .{};
            _ = closeFile(f);
        }
    }
    if (p.fd.grown) |grown| freeEntries(grown);
    p.fd = .{};
}

/// An empty table, for a new process slot (FreeBSD's fdinit).
pub fn fdinit(p: *proc.Proc) void {
    p.fd = .{};
}

/// Give `child` a copy of `parent`'s table (FreeBSD's fdcopy, at fork): the
/// same open files, each with one more reference, and the same flags.
/// Returns false when memory for the copy runs out.
pub fn fdcopy(parent: *proc.Proc, child: *proc.Proc) bool {
    const from: []Entry = parent.fd.entries();
    child.fd = .{};
    if (from.len > filedesc.NDFILE) {
        child.fd.grown = allocEntries(from.len) orelse return false;
    }
    const to: []Entry = child.fd.entries();
    @memcpy(to[0..from.len], from);
    for (to) |e| {
        if (e.file) |f| f.f_count += 1;
    }
    return true;
}
