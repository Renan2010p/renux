// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ext2fs vnode operations.
//
// This is the Zig counterpart of FreeBSD's sys/fs/ext2fs/ext2_vnops.c: the
// VFS entry points, each taking the mount's lock so a preempted operation
// never sees another half done. One vnode is cached per inode. An inode
// whose last name is removed while a file has it open is freed when the
// last open file is closed, as on FreeBSD.

const ext2fs: type = @import("ext2fs.zig");
const vnode: type = @import("../../sys/vnode.zig");
const mount: type = @import("../../sys/mount.zig");
const namei: type = @import("../../sys/namei.zig");
const dirent: type = @import("../../sys/dirent.zig");
const errno: type = @import("../../sys/errno.zig");
const vfs_subr: type = @import("../../core/vfs_subr.zig");
const kern_sx: type = @import("../../core/kern_sx.zig");
const kern_proc: type = @import("../../core/kern_proc.zig");
const kern_time: type = @import("../../core/kern_time.zig");

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
    .setattr = ext2Setattr,
    .rename = ext2Rename,
    .link = ext2Link,
};

/// The vnode operation vector ext2fs hands to the VFS.
pub const vnodeops: *const vnode.VnodeOps = &ext2_vnodeops;

/// The ext2fs mount behind a vnode.
fn mntOf(vp: *vnode.Vnode) ?*ext2fs.Ext2Mount {
    const mp: *mount.Mount = vp.v_mount orelse return null;
    return @ptrCast(@alignCast(mp.mnt_data orelse return null));
}

fn now() i64 {
    return @intCast(kern_time.now());
}

fn lock(mnt: *ext2fs.Ext2Mount) void {
    kern_sx.xlock(&mnt.lock);
}

/// Release the lock, first copying the superblock's counters into its
/// buffer so the syncer writes them with everything else.
fn unlock(mnt: *ext2fs.Ext2Mount) void {
    if (mnt.sb_dirty) ext2fs.writeSuper(mnt);
    kern_sx.xunlock(&mnt.lock);
}

/// The errno for a filesystem error.
fn errnoOf(e: ext2fs.Error) i32 {
    return switch (e) {
        error.NoSpace => errno.ENOSPC,
        error.Io => errno.EIO,
        error.TooBig => errno.EFBIG,
        error.ReadOnly => errno.EROFS,
    };
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

// -- vnode cache -------------------------------------------------------------------

fn cacheFind(mnt: *ext2fs.Ext2Mount, ino: u64) ?*ext2fs.CacheEntry {
    for (mnt.cache[0..mnt.ncache]) |*e| {
        if (e.ino == ino) return e;
    }
    return null;
}

/// Return (creating on first use) the vnode for inode `ino`.
pub fn getVnode(mnt: *ext2fs.Ext2Mount, mp: *mount.Mount, ino: u64) ?*vnode.Vnode {
    if (cacheFind(mnt, ino)) |e| return e.vp;
    const in: ext2fs.Inode = ext2fs.readInode(mnt, ino) orelse return null;
    const vp: *vnode.Vnode = vfs_subr.allocVnode(ext2fs.vtypeOf(in.mode), &ext2_vnodeops, null, mp) orelse return null;
    vp.v_ino = ino;
    if (mnt.ncache < ext2fs.CACHE_N) {
        mnt.cache[mnt.ncache] = .{ .ino = ino, .vp = vp };
        mnt.ncache += 1;
    }
    return vp;
}

/// Whether some open file still refers to the inode of `vp`.
pub fn openFiles(mnt: *ext2fs.Ext2Mount) u32 {
    var n: u32 = 0;
    for (mnt.cache[0..mnt.ncache]) |*e| n += e.opens;
    return n;
}

/// Drop one link from inode `ino`; free it when no link and no open file
/// remain (an open one is freed on its last close).
fn dropLink(mnt: *ext2fs.Ext2Mount, ino: u64, in: *ext2fs.Inode, all: bool) ext2fs.Error!void {
    if (all or in.nlink <= 1) in.nlink = 0 else in.nlink -= 1;
    in.ctime = now();
    if (in.nlink > 0) return ext2fs.writeInode(mnt, ino, in);
    if (cacheFind(mnt, ino)) |e| {
        if (e.opens > 0) {
            e.orphan = true;
            return ext2fs.writeInode(mnt, ino, in);
        }
        // The name is gone: the vnode must not find the freed inode again.
        e.ino = 0;
    }
    ext2fs.release(mnt, ino, in, now());
}

// -- operations --------------------------------------------------------------------

fn ext2Lookup(dvp: *vnode.Vnode, cnp: *const namei.Componentname) ?*vnode.Vnode {
    const mnt: *ext2fs.Ext2Mount = mntOf(dvp) orelse return null;
    const mp: *mount.Mount = dvp.v_mount orelse return null;
    lock(mnt);
    defer unlock(mnt);
    const dir: ext2fs.Inode = ext2fs.readInode(mnt, dvp.v_ino) orelse return null;
    const ino: u64 = ext2fs.dirLookup(mnt, &dir, cnp.nameptr[0..cnp.namelen]) orelse return null;
    return getVnode(mnt, mp, ino);
}

fn ext2Create(dvp: *vnode.Vnode, cnp: *const namei.Componentname, vap: *const vnode.Vattr) ?*vnode.Vnode {
    const mnt: *ext2fs.Ext2Mount = mntOf(dvp) orelse return null;
    const mp: *mount.Mount = dvp.v_mount orelse return null;
    const name: []const u8 = cnp.nameptr[0..cnp.namelen];
    if (name.len == 0 or name.len > 255 or mnt.readonly) return null;
    lock(mnt);
    defer unlock(mnt);

    var dir: ext2fs.Inode = ext2fs.readInode(mnt, dvp.v_ino) orelse return null;
    if (ext2fs.dirLookup(mnt, &dir, name)) |existing| {
        // O_CREAT on a name that appeared meanwhile: open what is there.
        return getVnode(mnt, mp, existing);
    }
    const isdir: bool = vap.type == .vdir;
    if (isdir and dir.nlink >= 65000) return null; // EXT2_LINK_MAX
    const ino: u64 = ext2fs.allocInode(mnt, dvp.v_ino, isdir) catch return null;
    const t: i64 = now();
    const p = kern_proc.current;
    var in: ext2fs.Inode = .{
        .mode = ext2fs.modeOf(vap.type) | (vap.mode & 0o7777),
        .uid = p.euid,
        // BSD semantics: a new file takes its directory's group.
        .gid = dir.gid,
        .nlink = if (isdir) 2 else 1,
        .atime = t,
        .mtime = t,
        .ctime = t,
    };
    if (vap.type == .vchr or vap.type == .vblk) in.block[0] = @truncate(vap.rdev);
    if (isdir) {
        ext2fs.dirInit(mnt, ino, &in, dvp.v_ino, t) catch {
            ext2fs.release(mnt, ino, &in, t);
            return null;
        };
    }
    ext2fs.writeInode(mnt, ino, &in) catch return null;
    ext2fs.dirEnter(mnt, dvp.v_ino, &dir, name, ino, in.mode, t) catch {
        ext2fs.release(mnt, ino, &in, t);
        return null;
    };
    if (isdir) {
        // The new directory's ".." links back to the parent.
        dir = ext2fs.readInode(mnt, dvp.v_ino) orelse return null;
        dir.nlink += 1;
        ext2fs.writeInode(mnt, dvp.v_ino, &dir) catch {};
    }
    return getVnode(mnt, mp, ino);
}

fn isDots(name: []const u8) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

fn ext2Remove(dvp: *vnode.Vnode, cnp: *const namei.Componentname) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(dvp) orelse return errno.EIO;
    const name: []const u8 = cnp.nameptr[0..cnp.namelen];
    if (isDots(name)) return errno.EINVAL;
    if (mnt.readonly) return errno.EROFS;
    lock(mnt);
    defer unlock(mnt);

    var dir: ext2fs.Inode = ext2fs.readInode(mnt, dvp.v_ino) orelse return errno.EIO;
    const ino: u64 = ext2fs.dirLookup(mnt, &dir, name) orelse return errno.ENOENT;
    var in: ext2fs.Inode = ext2fs.readInode(mnt, ino) orelse return errno.EIO;
    const isdir: bool = (in.mode & ext2fs.S_IFMT) == ext2fs.S_IFDIR;
    const want_dir: bool = (cnp.flags & namei.REQUIREDIR) != 0;
    if (isdir and !want_dir) return errno.EPERM; // unlink(2) of a directory
    if (!isdir and want_dir) return errno.ENOTDIR;
    if (isdir) {
        if (!ext2fs.dirEmpty(mnt, &in)) return errno.ENOTEMPTY;
        if (cacheFind(mnt, ino)) |e| {
            if (e.vp.v_mountedhere != null) return errno.EBUSY;
        }
    }
    _ = (ext2fs.dirRemove(mnt, dvp.v_ino, &dir, name, now()) catch |e| return errnoOf(e)) orelse return errno.ENOENT;
    if (isdir) {
        // Its ".." no longer links the parent; "." and the name go too.
        dir = ext2fs.readInode(mnt, dvp.v_ino) orelse return errno.EIO;
        dir.nlink -|= 1;
        ext2fs.writeInode(mnt, dvp.v_ino, &dir) catch |e| return errnoOf(e);
    }
    dropLink(mnt, ino, &in, isdir) catch |e| return errnoOf(e);
    return 0;
}

fn ext2Open(vp: *vnode.Vnode, mode: i32) i32 {
    _ = mode;
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return errno.EIO;
    lock(mnt);
    defer unlock(mnt);
    if (cacheFind(mnt, vp.v_ino)) |e| e.opens += 1;
    return 0;
}

fn ext2Close(vp: *vnode.Vnode, flags: i32) i32 {
    _ = flags;
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return 0;
    lock(mnt);
    defer unlock(mnt);
    const e: *ext2fs.CacheEntry = cacheFind(mnt, vp.v_ino) orelse return 0;
    if (e.opens > 0) e.opens -= 1;
    if (e.opens == 0 and e.orphan) {
        // The last open file of an unlinked inode: now it can go.
        e.orphan = false;
        const ino: u64 = e.ino;
        e.ino = 0;
        var in: ext2fs.Inode = ext2fs.readInode(mnt, ino) orelse return 0;
        ext2fs.release(mnt, ino, &in, now());
    }
    return 0;
}

fn ext2Read(vp: *vnode.Vnode, offset: u64, buf: []u8) isize {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return -errno.EIO;
    lock(mnt);
    defer unlock(mnt);
    const in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return -errno.EIO;
    return switch (ext2fs.vtypeOf(in.mode)) {
        .vlnk => ext2fs.readLink(mnt, &in, buf),
        .vreg => @intCast(ext2fs.readData(mnt, &in, offset, buf)),
        .vdir => -errno.EISDIR,
        else => -errno.EINVAL,
    };
}

fn ext2Write(vp: *vnode.Vnode, offset: u64, buf: []const u8) isize {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return -errno.EIO;
    if (mnt.readonly) return -errno.EROFS;
    lock(mnt);
    defer unlock(mnt);
    var in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return -errno.EIO;
    switch (ext2fs.vtypeOf(in.mode)) {
        .vreg => {
            const n: usize = ext2fs.writeData(mnt, vp.v_ino, &in, offset, buf, now()) catch |e| return -@as(isize, errnoOf(e));
            return @intCast(n);
        },
        .vlnk => {
            // A symbolic link gets its target written once, when created.
            if (offset != 0) return -errno.EINVAL;
            ext2fs.writeLink(mnt, vp.v_ino, &in, buf, now()) catch |e| return -@as(isize, errnoOf(e));
            return @intCast(buf.len);
        },
        .vdir => return -errno.EISDIR,
        else => return -errno.EINVAL,
    }
}

fn ext2Truncate(vp: *vnode.Vnode, length: u64) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return errno.EIO;
    if (mnt.readonly) return errno.EROFS;
    lock(mnt);
    defer unlock(mnt);
    var in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return errno.EIO;
    switch (ext2fs.vtypeOf(in.mode)) {
        .vreg => {},
        .vdir => return errno.EISDIR,
        else => return errno.EINVAL,
    }
    if (length > in.size) {
        // Growing leaves a hole; only the size changes.
        in.size = length;
        in.mtime = now();
        in.ctime = in.mtime;
        ext2fs.writeInode(mnt, vp.v_ino, &in) catch |e| return errnoOf(e);
        return 0;
    }
    ext2fs.truncate(mnt, vp.v_ino, &in, length, now()) catch |e| return errnoOf(e);
    return 0;
}

fn ext2Getattr(vp: *vnode.Vnode, vap: *vnode.Vattr) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return errno.EIO;
    lock(mnt);
    defer unlock(mnt);
    const in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return errno.EIO;
    vap.type = ext2fs.vtypeOf(in.mode);
    vap.mode = in.mode;
    vap.nlink = in.nlink;
    vap.size = in.size;
    vap.uid = in.uid;
    vap.gid = in.gid;
    // A device node stores its device number in the first block pointer.
    vap.rdev = if (vap.type == .vchr or vap.type == .vblk) in.block[0] else 0;
    vap.atime = in.atime;
    vap.mtime = in.mtime;
    vap.ctime = in.ctime;
    return 0;
}

fn ext2Setattr(vp: *vnode.Vnode, sa: *const vnode.Setattr) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return errno.EIO;
    if (mnt.readonly) return errno.EROFS;
    lock(mnt);
    defer unlock(mnt);
    var in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return errno.EIO;
    if (sa.mode) |m| in.mode = (in.mode & ext2fs.S_IFMT) | (m & 0o7777);
    if (sa.uid) |u| in.uid = u;
    if (sa.gid) |g| in.gid = g;
    if (sa.atime) |t| in.atime = t;
    if (sa.mtime) |t| in.mtime = t;
    in.ctime = now();
    ext2fs.writeInode(mnt, vp.v_ino, &in) catch |e| return errnoOf(e);
    return 0;
}

fn ext2Readdir(vp: *vnode.Vnode, offset: u64, buf: []u8, eofflag: *bool) isize {
    const mnt: *ext2fs.Ext2Mount = mntOf(vp) orelse return -errno.EIO;
    lock(mnt);
    defer unlock(mnt);
    const dir: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return -errno.EIO;
    if ((dir.mode & ext2fs.S_IFMT) != ext2fs.S_IFDIR) return -errno.ENOTDIR;

    var pos: u64 = offset;
    var used: usize = 0;
    var ent: ext2fs.DirEntry = undefined;
    eofflag.* = false;
    while (true) {
        const before: u64 = pos;
        if (!ext2fs.dirNext(mnt, &dir, &pos, &ent)) {
            eofflag.* = true;
            break;
        }
        const name: []const u8 = ent.name[0..ent.name_len];
        const total: usize = @sizeOf(dirent.Dirent) + name.len + 1;
        const reclen: usize = (total + 7) & ~@as(usize, 7);
        if (used + reclen > buf.len) {
            // No room: this entry starts the next call.
            pos = before;
            break;
        }
        const rec: *dirent.Dirent = @ptrCast(@alignCast(&buf[used]));
        rec.ino = ent.ino;
        rec.off = @intCast(pos);
        rec.reclen = @intCast(reclen);
        rec.type = dtypeOfFt(ent.ftype);
        if (rec.type == dirent.DT_UNKNOWN) {
            if (ext2fs.readInode(mnt, ent.ino)) |cin| {
                rec.type = switch (ext2fs.vtypeOf(cin.mode)) {
                    .vreg => dirent.DT_REG,
                    .vdir => dirent.DT_DIR,
                    .vlnk => dirent.DT_LNK,
                    .vchr => dirent.DT_CHR,
                    .vblk => dirent.DT_BLK,
                    .vfifo => dirent.DT_FIFO,
                    .vsock => dirent.DT_SOCK,
                    else => dirent.DT_UNKNOWN,
                };
            }
        }
        rec.namlen = @intCast(name.len);
        const name_dst: [*]u8 = @ptrFromInt(@intFromPtr(&buf[used]) + @sizeOf(dirent.Dirent));
        @memcpy(name_dst[0..name.len], name);
        name_dst[name.len] = 0;
        // Zero the padding so no kernel bytes leak to the program.
        @memset(name_dst[name.len + 1 .. reclen - @sizeOf(dirent.Dirent)], 0);
        used += reclen;
    }
    return @intCast(used);
}

/// Whether directory `ino` lies under (or is) directory `anc`: walk ".."
/// up to the root.
fn isAncestor(mnt: *ext2fs.Ext2Mount, anc: u64, ino: u64) bool {
    var cur: u64 = ino;
    var guard: u32 = 0;
    while (guard < 4096) : (guard += 1) {
        if (cur == anc) return true;
        if (cur == ext2fs.ROOT_INO) return false;
        const in: ext2fs.Inode = ext2fs.readInode(mnt, cur) orelse return false;
        const parent: u64 = ext2fs.dirLookup(mnt, &in, "..") orelse return false;
        if (parent == cur) return false;
        cur = parent;
    }
    return false;
}

fn ext2Rename(fdvp: *vnode.Vnode, fcnp: *const namei.Componentname, tdvp: *vnode.Vnode, tcnp: *const namei.Componentname) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(fdvp) orelse return errno.EIO;
    if (mnt.readonly) return errno.EROFS;
    const fname: []const u8 = fcnp.nameptr[0..fcnp.namelen];
    const tname: []const u8 = tcnp.nameptr[0..tcnp.namelen];
    if (isDots(fname) or isDots(tname)) return errno.EINVAL;
    if (tname.len > 255) return errno.ENAMETOOLONG;
    lock(mnt);
    defer unlock(mnt);
    const fdir_ino: u64 = fdvp.v_ino;
    const tdir_ino: u64 = tdvp.v_ino;
    const t: i64 = now();

    var fdir: ext2fs.Inode = ext2fs.readInode(mnt, fdir_ino) orelse return errno.EIO;
    const src: u64 = ext2fs.dirLookup(mnt, &fdir, fname) orelse return errno.ENOENT;
    var sin: ext2fs.Inode = ext2fs.readInode(mnt, src) orelse return errno.EIO;
    const sdir: bool = (sin.mode & ext2fs.S_IFMT) == ext2fs.S_IFDIR;
    // A directory cannot move under itself.
    if (sdir and fdir_ino != tdir_ino and isAncestor(mnt, src, tdir_ino)) return errno.EINVAL;

    var tdir: ext2fs.Inode = ext2fs.readInode(mnt, tdir_ino) orelse return errno.EIO;
    if (ext2fs.dirLookup(mnt, &tdir, tname)) |dst| {
        if (dst == src) return 0;
        var din: ext2fs.Inode = ext2fs.readInode(mnt, dst) orelse return errno.EIO;
        const ddir: bool = (din.mode & ext2fs.S_IFMT) == ext2fs.S_IFDIR;
        if (ddir and !sdir) return errno.EISDIR;
        if (!ddir and sdir) return errno.ENOTDIR;
        if (ddir and !ext2fs.dirEmpty(mnt, &din)) return errno.ENOTEMPTY;
        // The target name now names the source; the old target loses it.
        ext2fs.dirRewrite(mnt, &tdir, tname, src, sin.mode) catch |e| return errnoOf(e);
        if (ddir) {
            tdir = ext2fs.readInode(mnt, tdir_ino) orelse return errno.EIO;
            tdir.nlink -|= 1;
            ext2fs.writeInode(mnt, tdir_ino, &tdir) catch |e| return errnoOf(e);
        }
        dropLink(mnt, dst, &din, ddir) catch |e| return errnoOf(e);
    } else {
        ext2fs.dirEnter(mnt, tdir_ino, &tdir, tname, src, sin.mode, t) catch |e| return errnoOf(e);
    }

    fdir = ext2fs.readInode(mnt, fdir_ino) orelse return errno.EIO;
    _ = ext2fs.dirRemove(mnt, fdir_ino, &fdir, fname, t) catch |e| return errnoOf(e);

    if (sdir and fdir_ino != tdir_ino) {
        // The directory's ".." follows it to its new parent.
        sin = ext2fs.readInode(mnt, src) orelse return errno.EIO;
        ext2fs.dirRewrite(mnt, &sin, "..", tdir_ino, ext2fs.S_IFDIR) catch |e| return errnoOf(e);
        fdir = ext2fs.readInode(mnt, fdir_ino) orelse return errno.EIO;
        fdir.nlink -|= 1;
        ext2fs.writeInode(mnt, fdir_ino, &fdir) catch |e| return errnoOf(e);
        tdir = ext2fs.readInode(mnt, tdir_ino) orelse return errno.EIO;
        tdir.nlink += 1;
        ext2fs.writeInode(mnt, tdir_ino, &tdir) catch |e| return errnoOf(e);
    }
    sin = ext2fs.readInode(mnt, src) orelse return errno.EIO;
    sin.ctime = t;
    ext2fs.writeInode(mnt, src, &sin) catch |e| return errnoOf(e);
    return 0;
}

/// A hard link: a new entry for the inode of `vp`, and one more link count.
fn ext2Link(dvp: *vnode.Vnode, vp: *vnode.Vnode, cnp: *const namei.Componentname) i32 {
    const mnt: *ext2fs.Ext2Mount = mntOf(dvp) orelse return errno.EIO;
    if (mnt.readonly) return errno.EROFS;
    const name: []const u8 = cnp.nameptr[0..cnp.namelen];
    if (name.len > 255) return errno.ENAMETOOLONG;
    lock(mnt);
    defer unlock(mnt);
    var in: ext2fs.Inode = ext2fs.readInode(mnt, vp.v_ino) orelse return errno.EIO;
    if ((in.mode & ext2fs.S_IFMT) == ext2fs.S_IFDIR) return errno.EPERM;
    if (in.nlink >= 65000) return errno.EMLINK;
    var dir: ext2fs.Inode = ext2fs.readInode(mnt, dvp.v_ino) orelse return errno.EIO;
    if (ext2fs.dirLookup(mnt, &dir, name) != null) return errno.EEXIST;
    const t: i64 = now();
    in.nlink += 1;
    in.ctime = t;
    ext2fs.writeInode(mnt, vp.v_ino, &in) catch |e| return errnoOf(e);
    ext2fs.dirEnter(mnt, dvp.v_ino, &dir, name, vp.v_ino, in.mode, t) catch |e| {
        in.nlink -= 1;
        ext2fs.writeInode(mnt, vp.v_ino, &in) catch {};
        return errnoOf(e);
    };
    return 0;
}

fn ext2Inactive(vp: *vnode.Vnode) void {
    _ = vp;
}
