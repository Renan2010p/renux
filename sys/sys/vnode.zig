// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Vnode interface.
//
// This is the Zig counterpart of NetBSD's sys/sys/vnode.h, reduced to the
// pieces a first filesystem needs: the vnode type and attributes, the vector of
// operations a filesystem supplies (VnodeOps, NetBSD's struct vnodeops / the
// VOP_* macros), and the vnode header itself.
//
// A vnode is the kernel's handle on a file; everything above the VFS layer
// speaks in vnodes and never sees a filesystem's private structures. The
// filesystem hangs its own per-file data off v_data and implements the
// operations in v_op.

const mount: type = @import("mount.zig");
const namei: type = @import("namei.zig");

/// The kind of object a vnode refers to (NetBSD's enum vtype).
pub const Vtype: type = enum(u8) {
    vnone = 0, // no type (VNON)
    vreg, // regular file
    vdir, // directory
    vblk, // block device
    vchr, // character device
    vlnk, // symbolic link
    vsock, // socket
    vfifo, // FIFO
};

/// Attributes of a file, as returned by VOP_GETATTR (NetBSD's struct vattr).
pub const Vattr: type = struct {
    type: Vtype,
    /// Permission and file-type bits (S_IFMT | permission bits).
    mode: u16,
    /// Number of hard links.
    nlink: u32,
    /// Size in bytes.
    size: u64,
    uid: u32,
    gid: u32,
    /// Device number for VCHR/VBLK.
    rdev: u64,
    /// Access, modification and status-change times, in seconds.
    atime: i64,
    mtime: i64,
    ctime: i64,
};

/// The operations a filesystem provides on a vnode (NetBSD's struct vnodeops,
/// reached through the VOP_* macros). Every slot is filled; a filesystem that
/// does not support an operation points it at a stub that returns the right
/// error.
pub const VnodeOps: type = struct {
    /// Look up `cnp` in directory `dvp`. Returns the found vnode or null.
    lookup: *const fn (dvp: *Vnode, cnp: *const namei.Componentname) ?*Vnode,
    /// Create an entry `cnp` in directory `dvp` with attributes `vap`.
    create: *const fn (dvp: *Vnode, cnp: *const namei.Componentname, vap: *const Vattr) ?*Vnode,
    /// Remove the entry `cnp` from directory `dvp`; returns 0 or errno.
    remove: *const fn (dvp: *Vnode, cnp: *const namei.Componentname) i32,
    /// Open `vp` with the given access mode; called before reads or writes.
    open: *const fn (vp: *Vnode, mode: i32) i32,
    /// Called when the last reference to `vp` from an open file is dropped.
    close: *const fn (vp: *Vnode, flags: i32) i32,
    /// Read up to `buf.len` bytes at `offset`; returns the count or -errno.
    read: *const fn (vp: *Vnode, offset: u64, buf: []u8) isize,
    /// Write `buf` at `offset`; returns the count or -errno.
    write: *const fn (vp: *Vnode, offset: u64, buf: []const u8) isize,
    /// Fill in `vap` for `vp`; returns 0 or errno.
    getattr: *const fn (vp: *Vnode, vap: *Vattr) i32,
    /// Read directory entries into `buf`, starting at `offset`. Sets `eofflag`
    /// when the end of the directory is reached; returns the count or -errno.
    readdir: *const fn (vp: *Vnode, offset: u64, buf: []u8, eofflag: *bool) isize,
    /// Called when the kernel is done with `vp` and may reclaim it.
    inactive: *const fn (vp: *Vnode) void,
};

/// Vnode flags (NetBSD's VROOT and friends).
pub const VROOT: u32 = 0x0001; // vnode is the root of its filesystem

/// A vnode (NetBSD's struct vnode, reduced).
pub const Vnode: type = struct {
    /// What the vnode refers to.
    v_type: Vtype,
    /// Flags from the V* set above.
    v_flag: u32,
    /// Operations implemented by the filesystem.
    v_op: *const VnodeOps,
    /// Filesystem-private data (e.g. a tmpfs node).
    v_data: ?*anyopaque,
    /// Filesystem this vnode belongs to.
    v_mount: ?*mount.Mount,
    /// A filesystem mounted on this directory, if any. namei() crosses into
    /// mnt_root when it descends through the directory.
    v_mountedhere: ?*mount.Mount,
    /// Number of open references.
    v_usecount: u32,
    /// Number of internal references (name cache, parent links, ...).
    v_holdcnt: u32,
    /// Inode number, unique within the filesystem (used by stat/fstat).
    v_ino: u64,
};
