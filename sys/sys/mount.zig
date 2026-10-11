// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Mount interface.
//
// This is the Zig counterpart of NetBSD's sys/sys/mount.h, reduced to a
// filesystem's operation vector (Vfsops, NetBSD's struct vfsops), its type
// record (Vfs), and a mounted filesystem (Mount, NetBSD's struct mount).
//
// Machine-independent code reaches filesystems only through these structures,
// so adding a filesystem means registering a Vfs and nothing else.

const vnode: type = @import("vnode.zig");

/// Per-filesystem operations (NetBSD's struct vfsops).
pub const Vfsops: type = struct {
    /// Initialise `mp`'s private data and read the filesystem's root inode.
    mount: *const fn (mp: *Mount, data: ?*anyopaque) i32,
    /// Return the filesystem's root vnode.
    root: *const fn (mp: *Mount, vpp: *?*vnode.Vnode) i32,
    /// Flush and tear down `mp`.
    unmount: *const fn (mp: *Mount, flags: i32) i32,
    /// Fill in filesystem statistics for statfs(2) (unused so far).
    statvfs: *const fn (mp: *Mount) i32,
};

/// A filesystem type registered with the VFS (NetBSD's struct vfs).
pub const Vfs: type = struct {
    /// Name used to mount this filesystem (e.g. "tmpfs").
    name: []const u8,
    /// Operations implemented by the filesystem.
    ops: *const Vfsops,
    /// Next entry in the global list of filesystems.
    next: ?*Vfs,
};

/// A mounted filesystem (NetBSD's struct mount, reduced).
pub const Mount: type = struct {
    /// Operations of the mounted filesystem.
    mnt_op: *const Vfsops,
    /// Filesystem-private data (e.g. a tmpfs mount).
    mnt_data: ?*anyopaque,
    /// The root vnode of the filesystem.
    mnt_root: ?*vnode.Vnode,
    /// Mount flags (MNT_*; none used yet).
    mnt_flag: u32,
    /// Name of the mounted filesystem type.
    mnt_name: []const u8,
};
