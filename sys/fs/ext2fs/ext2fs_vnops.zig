// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ext2fs vnode operations.
//
// This is the Zig counterpart of NetBSD's sys/ufs/ext2fs/ext2fs_vnops.c,
// reduced to the read-only path: lookup, read, getattr and readdir, with the
// write operations returning EROFS. One vnode is cached per inode (the VFS
// does not reclaim vnodes yet), so repeated lookups of the same file share it.

const ext2fs: type = @import("ext2fs.zig");
const vnode: type = @import("../../sys/vnode.zig");
const mount: type = @import("../../sys/mount.zig");
const namei: type = @import("../../sys/namei.zig");
const file: type = @import("../../sys/file.zig");
const dirent: type = @import("../../sys/dirent.zig");
const errno: type = @import("../../sys/errno.zig");
const vfs_subr: type = @import("../../kern/vfs_subr.zig");

/// The operation vector ext2fs hands to the VFS.
const ext2_vnodeops: vnode.VnodeOps = .{
    .lookup = ext2Lookup,
    .create = ext2Create,
    .remove = ext2Remove,
    .open = ext2Open,
    .close = ext2Close,
    .read = ext2Read,
    .write = ext2Write,
    .truncate = ext2Truncate,
    .getattr = ext2Getattr,
    .readdir = ext2Readdir,
    .inactive = ext2Inactive,
};

/// Vnode cache, keyed by inode number. A single ext2fs mount exists at a time
/// (it is the root), so one global table is enough and keeps the mount record
/// small enough for the kmem allocator.
var vnode_cache: [ext2fs.CACHE_N]ext2fs.CacheEntry = undefined;
var vnode_ncache: usize = 0;

/// The ext2fs mount behind a vnode.
fn mntOf(vp: *vnode.Vnode) ?*ext2fs.Ext2Mount {
    const mp: *mount.Mount = vp.v_mount orelse return null;
    const raw: ?*anyopaque = mp.mnt_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// The DT_* code matching a directory entry's file-type byte.
fn dtypeOfFt(ft: u8) u8 {
    return switch (ft) {
        ext2fs.FT_REG => dirent.DT_REG,
        ext2fs.FT_DIR => dirent.DT_DIR,
        ext2fs.FT_CHR => dirent.DT_CHR,
        ext2fs.FT_BLK => dirent.DT_BLK,
        ext2fs.FT_FIFO => dirent.DT_FIFO,
        ext2fs.FT_SOCK => dirent.DT_SOCK,
        ext2fs.FT_LNK => dirent.DT_LNK,
        else => dirent.DT_UNKNOWN,
    };
}

/// Return (creating on first use) the vnode for inode `ino`.
pub fn getVnode(mnt: *ext2fs.Ext2Mount, mp: *mount.Mount, ino: u64) ?*vnode.Vnode {
    var i: usize = 0;
    while (i < vnode_ncache) : (i += 1) {
        if (vnode_cache[i].ino == ino) {
            return vnode_cache[i].vp;
        }
    }

    const in: ext2fs.Inode = ext2fs.readInode(mnt, ino) orelse return null;
    const vp: *vnode.Vnode = vfs_subr.allocVnode(ext2fs.vtypeOf(in.mode), &ext2_vnodeops, null, mp) orelse return null;
    vp.v_ino = ino;
    if (vnode_ncache < ext2fs.CACHE_N) {
        vnode_cache[vnode_ncache] = .{ .ino = ino, .vp = vp };
        vnode_ncache += 1;
    }
    return vp;
}

fn ext2Lookup(dvp: *vnode.Vnode, cnp: *const namei.Componentname) ?*vnode.Vnode {
    const mnt: *ext2fs.Ext2Mount = mntOf(dvp) orelse return null;
    const mp: *mount.Mount = dvp.v_mount orelse return null;
    const dir: ext2fs.Inode = ext2fs.readInode(mnt, dvp.v_ino) orelse return null;

    const name: []const u8 = cnp.nameptr[0..cnp.namelen];
    const ino: u64 = ext2fs.dirLookup(mnt, &dir, name) orelse return null;
    return getVnode(mnt, mp, ino);
}

fn ext2Create(dvp: *vnode.Vnode, cnp: *const namei.Componentname, vap: *const vnode.Vattr) ?*vnode.Vnode {
    _ = dvp;
    _ = cnp;
    _ = vap;
    return null; // read-only
}

fn ext2Remove(dvp: *vnode.Vnode, cnp: *const namei.Componentname) i32 {
    _ = dvp;
    _ = cnp;
    return errno.EROFS;
}

fn ext2Open(vp: *vnode.Vnode, mode: i32) i32 {
    _ = vp;
    _ = mode;
    return 0;
}

fn ext2Close(vp: *vnode.Vnode, flags: i32) i32 {
    _ = vp;
    _ = flags;
    return 0;
}

fn ext2Read(vp: *vnode.Vnode, offset: u64, buf: []u8) isize {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return -errno.EIO;
    const in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return -errno.EIO;
    return switch (ext2fs.vtypeOf(in.mode)) {
        .vlnk => ext2fs.readLink(mnt, &in, buf),
        .vreg => @intCast(ext2fs.readData(mnt, &in, offset, buf)),
        .vdir => -errno.EISDIR,
        else => -errno.EINVAL,
    };
}

fn ext2Write(vp: *vnode.Vnode, offset: u64, buf: []const u8) isize {
    _ = vp;
    _ = offset;
    _ = buf;
    return -errno.EROFS;
}

fn ext2Truncate(vp: *vnode.Vnode, length: u64) i32 {
    _ = vp;
    _ = length;
    return errno.EROFS;
}

fn ext2Getattr(vp: *vnode.Vnode, vap: *vnode.Vattr) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return errno.EIO;
    const in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return errno.EIO;

    vap.type = ext2fs.vtypeOf(in.mode);
    vap.mode = in.mode;
    vap.nlink = in.nlink;
    vap.size = in.size;
    vap.uid = in.uid;
    vap.gid = in.gid;
    // A device node stores its device number in the first block pointer.
    vap.rdev = in.block[0];
    vap.atime = in.atime;
    vap.mtime = in.mtime;
    vap.ctime = in.ctime;
    return 0;
}

fn ext2Readdir(vp: *vnode.Vnode, offset: u64, buf: []u8, eofflag: *bool) isize {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return -errno.EIO;
    const dir: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return -errno.EIO;
    if ((dir.mode & ext2fs.S_IFMT) != ext2fs.S_IFDIR) {
        return -errno.ENOTDIR;
    }

    var pos: u64 = offset;
    var used: usize = 0;
    eofflag.* = false;

    while (pos < dir.size) {
        const boff: u64 = pos % mnt.block_size;
        const bno: u64 = ext2fs.bmap(mnt, &dir, pos / mnt.block_size) orelse {
            eofflag.* = true;
            break;
        };
        const e: u64 = bno * mnt.block_size + boff;
        const ino: u32 = ext2fs.rd32(mnt.image, e);
        const rec_len: u16 = ext2fs.rd16(mnt.image, e + 4);
        if (rec_len < 8 or boff + rec_len > mnt.block_size) {
            eofflag.* = true;
            break;
        }

        if (ino != 0) {
            const name_len: usize = mnt.image[e + 6];
            if (e + 8 + name_len > mnt.image.len) {
                break;
            }
            const name: []const u8 = mnt.image[e + 8 .. e + 8 + name_len];

            const total: usize = @sizeOf(dirent.Dirent) + name.len + 1;
            const reclen: usize = (total + 7) & ~@as(usize, 7);
            if (used + reclen > buf.len) {
                break;
            }

            const rec: *dirent.Dirent = @ptrCast(@alignCast(&buf[used]));
            rec.ino = ino;
            rec.off = @intCast(pos + rec_len);
            rec.reclen = @intCast(reclen);
            rec.type = dtypeOfFt(mnt.image[e + 7]);
            rec.namlen = @intCast(name.len);

            const name_dst: [*]u8 = @ptrFromInt(@intFromPtr(&buf[used]) + @sizeOf(dirent.Dirent));
            var i: usize = 0;
            while (i < name.len) : (i += 1) {
                name_dst[i] = name[i];
            }
            name_dst[name.len] = 0;
            used += reclen;
        }
        pos += rec_len;
    }

    if (pos >= dir.size) {
        eofflag.* = true;
    }
    return @intCast(used);
}

fn ext2Inactive(vp: *vnode.Vnode) void {
    _ = vp;
}

/// The vnode operation vector ext2fs hands to the VFS.
pub const vnodeops: *const vnode.VnodeOps = &ext2_vnodeops;
