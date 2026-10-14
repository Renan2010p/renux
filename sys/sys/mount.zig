// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Mount interface.
//
// This is the Zig counterpart of FreeBSD's sys/sys/mount.h, reduced to a
// filesystem's operation vector (Vfsops, struct vfsops), its type record
// (Vfs, struct vfsconf), a mounted filesystem (Mount, struct mount) and the
// struct statfs that statfs(2), fstatfs(2) and getfsstat(2) return, laid out
// as FreeBSD/amd64 programs (mount, df) expect it.
//
// Machine-independent code reaches filesystems only through these structures,
// so adding a filesystem means registering a Vfs and nothing else.

const vnode: type = @import("vnode.zig");
const geom_disk: type = @import("../geom/geom_disk.zig");

/// Mount flags (MNT_*).
pub const MNT_RDONLY: u64 = 0x0000_0001;
pub const MNT_SYNCHRONOUS: u64 = 0x0000_0002;
pub const MNT_NOEXEC: u64 = 0x0000_0004;
pub const MNT_NOSUID: u64 = 0x0000_0008;
pub const MNT_LOCAL: u64 = 0x0000_1000;
pub const MNT_ROOTFS: u64 = 0x0000_4000;
pub const MNT_UPDATE: u64 = 0x0001_0000;
pub const MNT_FORCE: u64 = 0x0008_0000;
pub const MNT_BYFSID: u64 = 0x0800_0000;

/// Sizes of the name fields of struct statfs.
pub const MFSNAMELEN: usize = 16;
pub const MNAMELEN: usize = 1024;

/// statfs version stamp (STATFS_VERSION).
pub const STATFS_VERSION: u32 = 0x20140518;

/// struct statfs (FreeBSD 12 and later, 2344 bytes).
pub const Statfs: type = extern struct {
    f_version: u32,
    f_type: u32,
    f_flags: u64,
    f_bsize: u64,
    f_iosize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: i64,
    f_files: u64,
    f_ffree: i64,
    f_syncwrites: u64,
    f_asyncwrites: u64,
    f_syncreads: u64,
    f_asyncreads: u64,
    f_nvnodelistsize: u32,
    f_spare0: u32,
    f_spare: [9]u64,
    f_owner: u32,
    /// fsid_t is 8-byte aligned in the FreeBSD/amd64 ABI (f_fstypename is
    /// at offset 280, as df(1) and mount(8) read it).
    _pad_owner: u32 = 0,
    f_fsid: [2]i32,
    f_charspare: [80]u8,
    f_fstypename: [MFSNAMELEN]u8,
    f_mntfromname: [MNAMELEN]u8,
    f_mntonname: [MNAMELEN]u8,
};

comptime {
    if (@sizeOf(Statfs) != 2344) @compileError("mount: struct statfs must be 2344 bytes");
    if (@offsetOf(Statfs, "f_fstypename") != 280) @compileError("mount: f_fstypename must be at 280");
}

/// Per-filesystem operations (struct vfsops).
pub const Vfsops: type = struct {
    /// Initialise `mp`'s private data and read the filesystem's root inode.
    mount: *const fn (mp: *Mount, data: ?*anyopaque) i32,
    /// Return the filesystem's root vnode.
    root: *const fn (mp: *Mount, vpp: *?*vnode.Vnode) i32,
    /// Flush and tear down `mp` (MNT_FORCE in `flags` ignores open files).
    unmount: *const fn (mp: *Mount, flags: u64) i32,
    /// Fill in the counts of `sbp` (the names are the VFS's).
    statfs: *const fn (mp: *Mount, sbp: *Statfs) i32,
    /// Write everything the filesystem holds in memory to its disk.
    sync: ?*const fn (mp: *Mount) i32 = null,
    /// Whether an operation is in progress (the syncer then waits).
    busy: ?*const fn (mp: *Mount) bool = null,
};

/// A filesystem type registered with the VFS (struct vfsconf).
pub const Vfs: type = struct {
    /// Name used to mount this filesystem (e.g. "tmpfs").
    name: []const u8,
    /// Filesystem type number reported in f_type.
    typenum: u32 = 0,
    /// Operations implemented by the filesystem.
    ops: *const Vfsops,
    /// Next entry in the global list of filesystems.
    next: ?*Vfs,
};

/// A mounted filesystem (struct mount, reduced).
pub const Mount: type = struct {
    /// The slot is in use.
    mnt_used: bool = false,
    /// Operations of the mounted filesystem.
    mnt_op: *const Vfsops,
    /// The filesystem type.
    mnt_vfc: ?*Vfs = null,
    /// Filesystem-private data (e.g. a tmpfs mount).
    mnt_data: ?*anyopaque,
    /// The root vnode of the filesystem.
    mnt_root: ?*vnode.Vnode,
    /// The directory this filesystem is mounted on (null for the root).
    mnt_vnodecovered: ?*vnode.Vnode = null,
    /// The disk it lives on, if any.
    mnt_disk: ?*geom_disk.Disk = null,
    /// Mount flags (MNT_*).
    mnt_flag: u64,
    /// Name of the mounted filesystem type.
    mnt_name: []const u8,
    /// Where it is mounted, and what from (statfs's f_mntonname and
    /// f_mntfromname).
    mnt_onname: [MNAMELEN]u8 = @splat(0),
    mnt_fromname: [MNAMELEN]u8 = @splat(0),
};
