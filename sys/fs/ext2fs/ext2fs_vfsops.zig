// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ext2fs filesystem operations.
//
// This is the Zig counterpart of NetBSD's sys/ufs/ext2fs/ext2fs_vfsops.c,
// reduced to mounting a read-only image that already lives in memory (the boot
// loader loads the whole image as one module), returning the root inode, and
// the unmount/statvfs stubs. The filesystem registers itself with the VFS at
// SI_SUB_VFS.

const ext2fs: type = @import("ext2fs.zig");
const ext2fs_vnops: type = @import("ext2fs_vnops.zig");
const mount: type = @import("../../sys/mount.zig");
const vnode: type = @import("../../sys/vnode.zig");
const errno: type = @import("../../sys/errno.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const kmem: type = @import("../../kern/subr_kmem.zig");
const vfs_mount: type = @import("../../kern/vfs_mount.zig");
const prf: type = @import("../../kern/subr_prf.zig");

/// Prepare the mount from the in-memory image handed in `data` (an ext2fs.Args).
fn ext2Mount(mp: *mount.Mount, data: ?*anyopaque) i32 {
    const raw: ?*anyopaque = data orelse return errno.EINVAL;
    const args: *ext2fs.Args = @ptrCast(@alignCast(raw));

    const mnt: *ext2fs.Ext2Mount = kmem.zallocAs(ext2fs.Ext2Mount) orelse return errno.ENOMEM;
    if (!ext2fs.mountInit(mnt, args.image)) {
        return errno.EINVAL;
    }
    mp.mnt_data = mnt;
    return 0;
}

/// Return the filesystem's root vnode.
fn ext2Root(mp: *mount.Mount, vpp: *?*vnode.Vnode) i32 {
    const raw: ?*anyopaque = mp.mnt_data orelse return errno.EINVAL;
    const mnt: *ext2fs.Ext2Mount = @ptrCast(@alignCast(raw));
    vpp.* = ext2fs_vnops.getVnode(mnt, mp, ext2fs.ROOT_INO) orelse return errno.ENOMEM;
    return 0;
}

fn ext2Unmount(mp: *mount.Mount, flags: i32) i32 {
    _ = mp;
    _ = flags;
    return 0;
}

fn ext2Statvfs(mp: *mount.Mount) i32 {
    _ = mp;
    return 0;
}

/// The operation vector ext2fs hands to the VFS.
const ext2fs_vfsops: mount.Vfsops = .{
    .mount = ext2Mount,
    .root = ext2Root,
    .unmount = ext2Unmount,
    .statvfs = ext2Statvfs,
};

/// The filesystem record registered with the VFS.
var ext2_vfs: mount.Vfs = .{
    .name = "ext2fs",
    .ops = &ext2fs_vfsops,
    .next = null,
};

fn ext2Init(_: ?*const anyopaque) callconv(.c) void {
    vfs_mount.register(&ext2_vfs);
    prf.log(prf.LOG_INFO, "ext2fs: filesystem registered", .{});
}

comptime {
    sysinit.SYSINIT("sysinit_ext2", sysinit.SI_SUB_VFS, sysinit.SI_ORDER_SECOND, ext2Init, null);
}
