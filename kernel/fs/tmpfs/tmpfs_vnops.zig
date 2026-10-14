// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// tmpfs vnode operations.
//
// This is the Zig counterpart of NetBSD's sys/fs/tmpfs/tmpfs_vnops.c, reduced
// to the operations a first memory filesystem needs: lookup, create, read,
// write, getattr, readdir and the no-op open/close/inactive. Each node has at
// most one vnode, created lazily and cached on the node.

const tmpfs: type = @import("tmpfs.zig");
const kern_time: type = @import("../../core/kern_time.zig");
const tmpfs_subr: type = @import("tmpfs_subr.zig");
const vnode: type = @import("../../sys/vnode.zig");
const mount: type = @import("../../sys/mount.zig");
const namei: type = @import("../../sys/namei.zig");
const file: type = @import("../../sys/file.zig");
const dirent: type = @import("../../sys/dirent.zig");
const errno: type = @import("../../sys/errno.zig");
const vfs_subr: type = @import("../../core/vfs_subr.zig");

/// The operations every tmpfs vnode shares.
const tmpfs_vnodeops: vnode.VnodeOps = .{
    .lookup = tmpfsLookup,
    .create = tmpfsCreate,
    .remove = tmpfsRemove,
    .open = tmpfsOpen,
    .close = tmpfsClose,
    .read = tmpfsRead,
    .write = tmpfsWrite,
    .truncate = tmpfsTruncate,
    .getattr = tmpfsGetattr,
    .setattr = tmpfsSetattr,
    .rename = tmpfsRename,
    .link = tmpfsLink,
    .readdir = tmpfsReaddir,
    .inactive = tmpfsInactive,
};

/// The tmpfs node behind a vnode.
fn nodeOf(vp: *vnode.Vnode) *tmpfs.Node {
    const raw: ?*anyopaque = vp.v_data;
    return @ptrCast(@alignCast(raw.?));
}

/// The tmpfs mount behind a mount record.
fn mntOf(mp: *mount.Mount) *tmpfs.TmpfsMount {
    const raw: ?*anyopaque = mp.mnt_data;
    return @ptrCast(@alignCast(raw.?));
}

/// Return (creating on first use) the vnode for `node`.
pub fn getVnode(mp: *mount.Mount, node: *tmpfs.Node) ?*vnode.Vnode {
    if (node.vnode) |v| {
        return v;
    }
    const vp: *vnode.Vnode = vfs_subr.allocVnode(node.type, &tmpfs_vnodeops, node, mp) orelse return null;
    vp.v_ino = node.id;
    node.vnode = vp;
    return vp;
}

/// The DT_* type code matching a vnode type.
fn dtypeOf(t: vnode.Vtype) u8 {
    return switch (t) {
        .vreg => dirent.DT_REG,
        .vdir => dirent.DT_DIR,
        .vblk => dirent.DT_BLK,
        .vchr => dirent.DT_CHR,
        .vlnk => dirent.DT_LNK,
        .vfifo => dirent.DT_FIFO,
        else => dirent.DT_UNKNOWN,
    };
}

fn tmpfsLookup(dvp: *vnode.Vnode, cnp: *const namei.Componentname) ?*vnode.Vnode {
    const dir: *tmpfs.Node = nodeOf(dvp);
    if (dir.type != .vdir) {
        return null;
    }
    const mp: *mount.Mount = dvp.v_mount orelse return null;

    // ".." is answered from the directory itself.
    if (cnp.namelen == 2 and cnp.nameptr[0] == '.' and cnp.nameptr[1] == '.') {
        const parent: *tmpfs.Node = dir.parent orelse dir;
        return getVnode(mp, parent);
    }

    const de: *tmpfs.Dirent = tmpfs_subr.dirLookup(dir, cnp) orelse return null;
    return getVnode(mp, de.node);
}

fn tmpfsCreate(dvp: *vnode.Vnode, cnp: *const namei.Componentname, vap: *const vnode.Vattr) ?*vnode.Vnode {
    const dir: *tmpfs.Node = nodeOf(dvp);
    if (dir.type != .vdir) {
        return null;
    }
    const mp: *mount.Mount = dvp.v_mount orelse return null;
    const mnt: *tmpfs.TmpfsMount = mntOf(mp);

    if (tmpfs_subr.dirLookup(dir, cnp) != null) {
        return null; // already exists
    }

    const node: *tmpfs.Node = tmpfs_subr.allocNode(mnt, vap.type) orelse return null;
    node.mode = vap.mode;
    node.nlink = 1;
    node.rdev = vap.rdev;
    node.parent = dir;
    if (vap.type == .vdir) {
        node.nlink = 2;
        dir.nlink += 1;
    }

    const de: *tmpfs.Dirent = tmpfs_subr.allocDirent(cnp.nameptr[0..cnp.namelen]) orelse {
        tmpfs_subr.freeNode(node);
        return null;
    };
    de.node = node;
    tmpfs_subr.dirAttach(dir, de);

    return getVnode(mp, node);
}

fn tmpfsRemove(dvp: *vnode.Vnode, cnp: *const namei.Componentname) i32 {
    const dir: *tmpfs.Node = nodeOf(dvp);
    if (dir.type != .vdir) {
        return errno.ENOTDIR;
    }
    const require_dir: bool = (cnp.flags & namei.REQUIREDIR) != 0;

    const de: *tmpfs.Dirent = tmpfs_subr.dirLookup(dir, cnp) orelse return errno.ENOENT;
    const node: *tmpfs.Node = de.node;
    if (require_dir) {
        if (node.type != .vdir) {
            return errno.ENOTDIR;
        }
        if (node.entries != null) {
            return errno.ENOTEMPTY;
        }
    } else if (node.type == .vdir) {
        return errno.EISDIR;
    }

    _ = tmpfs_subr.dirDetach(dir, de);
    tmpfs_subr.freeDirent(de);
    if (node.type == .vdir) {
        dir.nlink -= 1;
        node.nlink = 0;
    } else {
        // Other names (hard links) may remain.
        node.nlink -|= 1;
    }
    // The node itself is left allocated: a cached vnode may still refer to it.
    return 0;
}

/// A hard link: one more directory entry for the same node.
fn tmpfsLink(dvp: *vnode.Vnode, vp: *vnode.Vnode, cnp: *const namei.Componentname) i32 {
    const dir: *tmpfs.Node = nodeOf(dvp);
    const node: *tmpfs.Node = nodeOf(vp);
    if (dir.type != .vdir) return errno.ENOTDIR;
    if (node.type == .vdir) return errno.EPERM;
    if (tmpfs_subr.dirLookup(dir, cnp) != null) return errno.EEXIST;
    const de: *tmpfs.Dirent = tmpfs_subr.allocDirent(cnp.nameptr[0..cnp.namelen]) orelse return errno.ENOMEM;
    de.node = node;
    tmpfs_subr.dirAttach(dir, de);
    node.nlink += 1;
    return 0;
}

/// Move an entry, as FreeBSD's tmpfs_rename(): the target name, if it
/// exists, is replaced (a directory only by a directory, and only if empty);
/// a directory may not move into its own subtree.
fn tmpfsRename(fdvp: *vnode.Vnode, fcnp: *const namei.Componentname, tdvp: *vnode.Vnode, tcnp: *const namei.Componentname) i32 {
    const fdir: *tmpfs.Node = nodeOf(fdvp);
    const tdir: *tmpfs.Node = nodeOf(tdvp);
    if (fdir.type != .vdir or tdir.type != .vdir) return errno.ENOTDIR;

    const fde: *tmpfs.Dirent = tmpfs_subr.dirLookup(fdir, fcnp) orelse return errno.ENOENT;
    const node: *tmpfs.Node = fde.node;

    // A directory cannot become its own descendant.
    if (node.type == .vdir) {
        var up: ?*tmpfs.Node = tdir;
        while (up) |d| {
            if (d == node) return errno.EINVAL;
            if (d.parent == d) break;
            up = d.parent;
        }
    }

    if (tmpfs_subr.dirLookup(tdir, tcnp)) |tde| {
        const target: *tmpfs.Node = tde.node;
        if (target == node) return 0; // same file: nothing to do
        if (target.type == .vdir) {
            if (node.type != .vdir) return errno.EISDIR;
            if (target.entries != null) return errno.ENOTEMPTY;
            tdir.nlink -= 1;
        } else if (node.type == .vdir) {
            return errno.ENOTDIR;
        }
        _ = tmpfs_subr.dirDetach(tdir, tde);
        tmpfs_subr.freeDirent(tde);
        target.nlink = 0;
    }

    const nde: *tmpfs.Dirent = tmpfs_subr.allocDirent(tcnp.nameptr[0..tcnp.namelen]) orelse return errno.ENOSPC;
    nde.node = node;
    tmpfs_subr.dirAttach(tdir, nde);
    _ = tmpfs_subr.dirDetach(fdir, fde);
    tmpfs_subr.freeDirent(fde);

    if (node.type == .vdir and fdir != tdir) {
        node.parent = tdir;
        fdir.nlink -= 1;
        tdir.nlink += 1;
    }
    return 0;
}

fn tmpfsOpen(vp: *vnode.Vnode, mode: i32) i32 {
    const node: *tmpfs.Node = nodeOf(vp);
    if (node.type == .vdir and (mode & file.FWRITE) != 0) {
        return errno.EISDIR;
    }
    return 0;
}

fn tmpfsClose(vp: *vnode.Vnode, flags: i32) i32 {
    _ = vp;
    _ = flags;
    return 0;
}

fn tmpfsRead(vp: *vnode.Vnode, offset: u64, buf: []u8) isize {
    const node: *tmpfs.Node = nodeOf(vp);
    // Regular files and symbolic links store their bytes the same way; a link's
    // contents are its target.
    if (node.type != .vreg and node.type != .vlnk) {
        return -errno.EISDIR;
    }
    return @intCast(tmpfs_subr.regRead(node, offset, buf));
}

fn tmpfsWrite(vp: *vnode.Vnode, offset: u64, buf: []const u8) isize {
    const node: *tmpfs.Node = nodeOf(vp);
    if (node.type != .vreg and node.type != .vlnk) {
        return -errno.EISDIR;
    }
    const n: usize = tmpfs_subr.regWrite(node, offset, buf);
    if (n > 0) {
        node.mtime = @intCast(kern_time.now());
        node.ctime = node.mtime;
    }
    return @intCast(n);
}

fn tmpfsTruncate(vp: *vnode.Vnode, length: u64) i32 {
    const node: *tmpfs.Node = nodeOf(vp);
    if (node.type != .vreg) {
        return errno.EISDIR;
    }
    tmpfs_subr.regTruncate(node, length);
    return 0;
}

fn tmpfsSetattr(vp: *vnode.Vnode, sa: *const vnode.Setattr) i32 {
    const node: *tmpfs.Node = nodeOf(vp);
    if (sa.mode) |m| node.mode = (node.mode & ~@as(u16, 0o7777)) | (m & 0o7777);
    if (sa.uid) |u| node.uid = u;
    if (sa.gid) |g| node.gid = g;
    if (sa.atime) |t| node.atime = t;
    if (sa.mtime) |t| node.mtime = t;
    return 0;
}

fn tmpfsGetattr(vp: *vnode.Vnode, vap: *vnode.Vattr) i32 {
    const node: *tmpfs.Node = nodeOf(vp);
    vap.type = node.type;
    vap.mode = node.mode;
    vap.nlink = node.nlink;
    vap.size = node.size;
    vap.uid = node.uid;
    vap.gid = node.gid;
    vap.rdev = node.rdev;
    vap.atime = node.atime;
    vap.mtime = node.mtime;
    vap.ctime = node.ctime;
    return 0;
}

fn tmpfsReaddir(vp: *vnode.Vnode, offset: u64, buf: []u8, eofflag: *bool) isize {
    const dir: *tmpfs.Node = nodeOf(vp);
    if (dir.type != .vdir) {
        return -errno.ENOTDIR;
    }

    var off: u64 = offset;
    var used: usize = 0;
    eofflag.* = false;

    while (true) {
        var name: []const u8 = undefined;
        var ino: u64 = 0;
        var dtype: u8 = dirent.DT_UNKNOWN;

        if (off == 0) {
            name = ".";
            ino = dir.id;
            dtype = dirent.DT_DIR;
        } else if (off == 1) {
            const parent: *tmpfs.Node = dir.parent orelse dir;
            name = "..";
            ino = parent.id;
            dtype = dirent.DT_DIR;
        } else {
            const de: *tmpfs.Dirent = tmpfs_subr.nthEntry(dir, @intCast(off - 2)) orelse {
                eofflag.* = true;
                break;
            };
            name = de.name;
            ino = de.node.id;
            dtype = dtypeOf(de.node.type);
        }

        // Header plus the name and its NUL, padded to an eight-byte boundary.
        const total: u64 = @sizeOf(dirent.Dirent) + name.len + 1;
        const reclen: u64 = (total + 7) & ~@as(u64, 7);
        if (used + reclen > buf.len) {
            break;
        }

        const rec: *dirent.Dirent = @ptrCast(@alignCast(&buf[used]));
        rec.ino = ino;
        rec.off = @intCast(off + 1);
        rec.reclen = @intCast(reclen);
        rec.type = dtype;
        rec.namlen = @intCast(name.len);

        const name_dst: [*]u8 = @ptrFromInt(@intFromPtr(&buf[used]) + @sizeOf(dirent.Dirent));
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            name_dst[i] = name[i];
        }
        name_dst[name.len] = 0;

        used += @intCast(reclen);
        off += 1;
    }

    return @intCast(used);
}

fn tmpfsInactive(vp: *vnode.Vnode) void {
    _ = vp;
}
