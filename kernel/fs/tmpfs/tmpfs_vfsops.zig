// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// tmpfs filesystem operations.
//
// This is the Zig counterpart of NetBSD's sys/fs/tmpfs/tmpfs_vfsops.c, reduced
// to mounting (which builds the root node), returning the root vnode, and the
// stubs for unmount/statvfs. The filesystem registers itself with the VFS at
// SI_SUB_VFS.

const tmpfs: type = @import("tmpfs.zig");
const tmpfs_subr: type = @import("tmpfs_subr.zig");
const tmpfs_vnops: type = @import("tmpfs_vnops.zig");
const mount: type = @import("../../sys/mount.zig");
const vnode: type = @import("../../sys/vnode.zig");
const errno: type = @import("../../sys/errno.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const kmem: type = @import("../../core/subr_kmem.zig");
const param: type = @import("../../sys/param.zig");
const vm_page: type = @import("../../vm/vm_page.zig");
const vfs_mount: type = @import("../../core/vfs_mount.zig");
const prf: type = @import("../../core/subr_prf.zig");

/// Create the mount's private state and its root node.
fn tmpfsMount(mp: *mount.Mount, data: ?*anyopaque) i32 {
    _ = data;
    const mnt: *tmpfs.TmpfsMount = kmem.zallocAs(tmpfs.TmpfsMount) orelse return errno.ENOMEM;
    mnt.next_id = 1;

    const root: *tmpfs.Node = tmpfs_subr.allocNode(mnt, .vdir) orelse return errno.ENOMEM;
    root.id = 0;
    root.mode = 0o755;
    root.nlink = 2;
    root.parent = root;
    mnt.root = root;

    mp.mnt_data = mnt;
    return 0;
}

/// Return the filesystem's root vnode.
fn tmpfsRoot(mp: *mount.Mount, vpp: *?*vnode.Vnode) i32 {
    const raw: ?*anyopaque = mp.mnt_data orelse return errno.EINVAL;
    const mnt: *tmpfs.TmpfsMount = @ptrCast(@alignCast(raw));
    vpp.* = tmpfs_vnops.getVnode(mp, mnt.root) orelse return errno.ENOMEM;
    return 0;
}

fn tmpfsUnmount(mp: *mount.Mount, flags: u64) i32 {
    _ = mp;
    _ = flags;
    return 0;
}

/// tmpfs lives in memory: report the page pool as its space, as FreeBSD's
/// tmpfs_statfs does.
fn tmpfsStatfs(mp: *mount.Mount, sbp: *mount.Statfs) i32 {
    _ = mp;
    sbp.f_bsize = param.PAGE_SIZE;
    sbp.f_iosize = param.PAGE_SIZE;
    sbp.f_blocks = vm_page.totalPages();
    sbp.f_bfree = vm_page.freeCount();
    sbp.f_bavail = @intCast(vm_page.freeCount());
    sbp.f_files = vm_page.totalPages();
    sbp.f_ffree = @intCast(vm_page.freeCount());
    return 0;
}

/// The operation vector tmpfs hands to the VFS.
const tmpfs_vfsops: mount.Vfsops = .{
    .mount = tmpfsMount,
    .root = tmpfsRoot,
    .unmount = tmpfsUnmount,
    .statfs = tmpfsStatfs,
};

/// The filesystem record registered with the VFS.
var tmpfs_vfs: mount.Vfs = .{
    .name = "tmpfs",
    .typenum = 0x87,
    .ops = &tmpfs_vfsops,
    .next = null,
};

fn tmpfsInit(_: ?*const anyopaque) callconv(.c) void {
    vfs_mount.register(&tmpfs_vfs);
    prf.log(prf.LOG_INFO, "tmpfs: filesystem registered", .{});
}

comptime {
    sysinit.SYSINIT("sysinit_tmpfs", sysinit.SI_SUB_VFS, sysinit.SI_ORDER_FIRST, tmpfsInit, null);
}
