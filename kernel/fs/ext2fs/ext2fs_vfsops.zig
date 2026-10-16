// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ext2fs filesystem operations.
//
// This is the Zig counterpart of FreeBSD's sys/fs/ext2fs/ext2_vfsops.c:
// mounting an ext2 filesystem from a disk (read-write when its features
// allow it), returning the root inode, syncing, statfs, and unmounting.
// A read-write mount clears the superblock's "clean" state and sets it again
// on unmount, so e2fsck knows whether the filesystem was shut down cleanly.

const ext2fs: type = @import("ext2fs.zig");
const ext2fs_vnops: type = @import("ext2fs_vnops.zig");
const mount: type = @import("../../sys/mount.zig");
const vnode: type = @import("../../sys/vnode.zig");
const errno: type = @import("../../sys/errno.zig");
const param: type = @import("../../sys/param.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const arch: type = @import("../../arch/arch.zig");
const kmem: type = @import("../../core/subr_kmem.zig");
const vm_page: type = @import("../../vm/vm_page.zig");
const vfs_mount: type = @import("../../core/vfs_mount.zig");
const vfs_bio: type = @import("../../core/vfs_bio.zig");
const kern_sx: type = @import("../../core/kern_sx.zig");
const kern_time: type = @import("../../core/kern_time.zig");
const geom_disk: type = @import("../../geom/geom_disk.zig");
const prf: type = @import("../../core/subr_prf.zig");

/// FreeBSD's vfsconf type number for ext2fs.
const EXT2FS_TYPENUM: u32 = 0x2e;

fn mntOf(mp: *mount.Mount) ?*ext2fs.Ext2Mount {
    return @ptrCast(@alignCast(mp.mnt_data orelse return null));
}

/// Pages holding a mount's vnode cache.
const CACHE_PAGES: u64 = (ext2fs.CACHE_N * @sizeOf(ext2fs.CacheEntry) + param.PAGE_SIZE - 1) / param.PAGE_SIZE;

/// Mount the filesystem described by `data` (an ext2fs.Args naming a disk).
fn ext2Mount(mp: *mount.Mount, data: ?*anyopaque) i32 {
    const args: *ext2fs.Args = @ptrCast(@alignCast(data orelse return errno.EINVAL));
    const dp: *geom_disk.Disk = args.disk orelse return errno.EINVAL;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return errno.ENOMEM;

    const mnt: *ext2fs.Ext2Mount = kmem.zallocAs(ext2fs.Ext2Mount) orelse return errno.ENOMEM;
    if (!ext2fs.mountDisk(mnt, dp, args.readonly)) {
        kmem.freeAs(ext2fs.Ext2Mount, mnt);
        return errno.EINVAL;
    }
    const pa: u64 = (vm_page.physallocContig(CACHE_PAGES) orelse {
        kmem.freeAs(ext2fs.Ext2Mount, mnt);
        return errno.ENOMEM;
    }).int();
    mnt.cache = @ptrFromInt(pa + hhdm);
    mnt.ncache = 0;
    if (mnt.readonly) mp.mnt_flag |= mount.MNT_RDONLY;

    var name: [16]u8 = undefined;
    const dev: []const u8 = geom_disk.devName(dp, &name);
    if (!args.readonly and mnt.readonly) {
        prf.printf("WARNING: %s: R/W mount denied: the file system uses features this ext2fs cannot keep consistent; mounted read-only\n", .{dev});
    }
    if (!mnt.readonly) {
        if ((ext2fs.superState(mnt) & ext2fs.EXT2_VALID_FS) == 0) {
            prf.printf("WARNING: %s: file system was not properly unmounted; check it with e2fsck\n", .{dev});
        }
        // Mark it in use until a clean unmount.
        ext2fs.setSuperState(mnt, ext2fs.superState(mnt) & ~ext2fs.EXT2_VALID_FS);
        ext2fs.noteMount(mnt, @truncate(kern_time.now()));
        ext2fs.writeSuper(mnt);
        _ = vfs_bio.bflush(dp);
    }
    mp.mnt_data = mnt;
    mp.mnt_disk = dp;
    return 0;
}

/// Return the filesystem's root vnode.
fn ext2Root(mp: *mount.Mount, vpp: *?*vnode.Vnode) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(mp) orelse return errno.EINVAL;
    kern_sx.xlock(&mnt.lock);
    defer kern_sx.xunlock(&mnt.lock);
    vpp.* = ext2fs_vnops.getVnode(mnt, mp, ext2fs.ROOT_INO) orelse return errno.ENOMEM;
    return 0;
}

/// Write the superblock and every dirty buffer of the filesystem.
fn ext2Sync(mp: *mount.Mount) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(mp) orelse return 0;
    if (mnt.readonly) return 0;
    kern_sx.xlock(&mnt.lock);
    defer kern_sx.xunlock(&mnt.lock);
    ext2fs.writeSuper(mnt);
    return vfs_bio.bflush(mnt.disk);
}

fn ext2Unmount(mp: *mount.Mount, flags: u64) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(mp) orelse return 0;
    kern_sx.xlock(&mnt.lock);
    if ((flags & mount.MNT_FORCE) == 0 and ext2fs_vnops.openFiles(mnt) > 0) {
        kern_sx.xunlock(&mnt.lock);
        return errno.EBUSY;
    }
    const dp: *geom_disk.Disk = mnt.disk.?;
    if (!mnt.readonly) {
        // Clean again: everything is about to be on the disk.
        ext2fs.setSuperState(mnt, ext2fs.superState(mnt) | ext2fs.EXT2_VALID_FS);
        ext2fs.writeSuper(mnt);
    }
    const e: i32 = vfs_bio.bflush(dp);
    vfs_bio.binval(dp);
    kern_sx.xunlock(&mnt.lock);
    if (e != 0) return e;
    // The cached vnodes stay allocated (the VFS never frees vnodes); they
    // keep pointing at a mount that is gone and are never looked up again.
    mp.mnt_data = null;
    return 0;
}

fn ext2Statfs(mp: *mount.Mount, sbp: *mount.Statfs) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(mp) orelse return errno.EINVAL;
    const bs: u64 = mnt.block_size;
    sbp.f_bsize = bs;
    sbp.f_iosize = bs;
    // Like FreeBSD's ext2_statfs: the metadata at the start of each group
    // (superblock copies, descriptors, bitmaps, inode tables) is not
    // counted as space.
    const itable_blocks: u64 = (mnt.inodes_per_group * mnt.inode_size + bs - 1) / bs;
    const overhead: u64 = mnt.first_data_block + mnt.ngroups * (2 + itable_blocks);
    sbp.f_blocks = mnt.blocks_count -| overhead;
    const free: u64 = ext2fs.freeBlocks(mnt);
    sbp.f_bfree = free;
    sbp.f_bavail = @as(i64, @intCast(free)) - @as(i64, @intCast(ext2fs.reservedBlocks(mnt)));
    sbp.f_files = mnt.inodes_count;
    sbp.f_ffree = @intCast(ext2fs.freeInodes(mnt));
    return 0;
}

fn ext2Busy(mp: *mount.Mount) bool {
    const mnt: *ext2fs.Ext2Mount = mntOf(mp) orelse return false;
    return kern_sx.xlocked(&mnt.lock);
}

/// The operation vector ext2fs hands to the VFS.
const ext2fs_vfsops: mount.Vfsops = .{
    .mount = ext2Mount,
    .root = ext2Root,
    .unmount = ext2Unmount,
    .statfs = ext2Statfs,
    .sync = ext2Sync,
    .busy = ext2Busy,
};

/// The filesystem record registered with the VFS.
var ext2_vfs: mount.Vfs = .{
    .name = "ext2fs",
    .typenum = EXT2FS_TYPENUM,
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
