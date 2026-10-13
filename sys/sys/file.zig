// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Open-file table entries.
//
// This is the Zig counterpart of NetBSD's sys/sys/file.h, reduced to the entry
// that backs a file descriptor: a File describes an open file (its type, flags,
// offset and filesystem handle) and points at a FileOps vector that decides how
// read()/write()/close() act on it. A vnode-backed file dispatches to the
// vnode's VOP_READ/VOP_WRITE.

const stat: type = @import("stat.zig");

/// File descriptor flags (the F* bits, stored in f_flag).
pub const FREAD: i32 = 0x0001;
pub const FWRITE: i32 = 0x0002;

/// File types (the f_type field), matching NetBSD's DTYPE_*.
pub const DTYPE_VNODE: u8 = 1;
pub const DTYPE_SOCKET: u8 = 2;
pub const DTYPE_PIPE: u8 = 3;

/// poll(2) event bits (FreeBSD's sys/poll.h), as FileOps.poll reports them.
pub const POLLIN: u16 = 0x0001;
pub const POLLOUT: u16 = 0x0004;
pub const POLLERR: u16 = 0x0008;
pub const POLLHUP: u16 = 0x0010;
pub const POLLNVAL: u16 = 0x0020;

/// Operations on an open file (NetBSD's struct fileops).
pub const FileOps: type = struct {
    /// Read up to `buf.len` bytes at the file's current offset, advancing it.
    read: *const fn (f: *File, buf: []u8) isize,
    /// Write `buf` at the file's current offset, advancing it.
    write: *const fn (f: *File, buf: []const u8) isize,
    /// Handle an ioctl(2) request, if the file supports it.
    ioctl: ?*const fn (f: *File, cmd: u64, arg: u64) i32 = null,
    /// Map device memory: return the physical address for `offset`, or null.
    mmap: ?*const fn (f: *File, offset: u64, prot: u32) ?u64 = null,
    /// Fill in `st` for fstat(2).
    stat: *const fn (f: *File, st: *stat.Stat) i32,
    /// Drop the descriptor's reference to the file.
    close: *const fn (f: *File) i32,
    /// Readiness for poll(2): the POLL* bits that hold now. Files without it
    /// are treated as the console (input when the console has some) for
    /// devices, and always ready otherwise.
    poll: ?*const fn (f: *File) u16 = null,
};

/// An open file (NetBSD's struct file).
pub const File: type = struct {
    /// One of the DTYPE_* values above.
    f_type: u8,
    /// Access flags (FREAD/FWRITE).
    f_flag: i32,
    /// Current read/write offset.
    f_offset: u64,
    /// Number of descriptors referring to this entry.
    f_count: u32,
    /// The object the file refers to (e.g. a *vnode.Vnode).
    f_data: ?*anyopaque,
    /// Operations for this kind of file.
    f_ops: *const FileOps,
    /// For an open directory: its absolute path (a MAXPATHLEN kmem buffer),
    /// which fchdir(2) needs because Renux tracks the working directory by
    /// name. Null for everything else.
    f_path: ?[*]u8 = null,
    f_pathlen: usize = 0,
};
