// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Vnode-level operations.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_vnops.c, reduced to
// three things: opening a path into an open file (vn_open), creating a file or
// directory during bring-up (vn_create), and the FileOps vector that makes a
// vnode-backed descriptor read, write, stat and close through its vnode.

const vnode: type = @import("../sys/vnode.zig");
const namei: type = @import("../sys/namei.zig");
const file: type = @import("../sys/file.zig");
const stat: type = @import("../sys/stat.zig");
const errno: type = @import("../sys/errno.zig");
const fcntl: type = @import("../sys/fcntl.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_mount: type = @import("vfs_mount.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const subr_devsw: type = @import("subr_devsw.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kmem: type = @import("subr_kmem.zig");

/// The FileOps used by every vnode-backed descriptor.
pub const vnode_ops: file.FileOps = .{
    .read = vnodeRead,
    .write = vnodeWrite,
    .stat = vnodeStat,
    .close = vnodeClose,
};

/// Turn a vnode's attributes into a struct stat.
pub fn fillStat(vp: *vnode.Vnode, st: *stat.Stat) i32 {
    var vap: vnode.Vattr = .{
        .type = .vnone,
        .mode = 0,
        .nlink = 0,
        .size = 0,
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    const err: i32 = vp.v_op.getattr(vp, &vap);
    if (err != 0) {
        return err;
    }

    st.dev = 0;
    st.ino = vp.v_ino;
    st.nlink = vap.nlink;
    st.mode = @truncate(@as(u32, vap.mode) | typeBits(vap.type));
    st.padding0 = 0;
    st.uid = vap.uid;
    st.gid = vap.gid;
    st.padding1 = 0;
    st.rdev = vap.rdev;
    st.atim = .{ .sec = vap.atime, .nsec = 0 };
    st.mtim = .{ .sec = vap.mtime, .nsec = 0 };
    st.ctim = .{ .sec = vap.ctime, .nsec = 0 };
    st.size = @intCast(vap.size);
    st.blocks = @intCast((vap.size + 511) / 512);
    st.blksize = 4096;
    st.flags = 0;
    st.gen = 0;
    st.spare = @splat(0);
    st.birthtim = .{ .sec = vap.ctime, .nsec = 0 };
    return 0;
}

/// The S_IFMT bits matching a vnode type.
fn typeBits(t: vnode.Vtype) u32 {
    return switch (t) {
        .vreg => stat.S_IFREG,
        .vdir => stat.S_IFDIR,
        .vblk => stat.S_IFBLK,
        .vchr => stat.S_IFCHR,
        .vlnk => stat.S_IFLNK,
        .vfifo => stat.S_IFIFO,
        else => 0,
    };
}

fn vnodeRead(f: *file.File, buf: []u8) isize {
    const raw: ?*anyopaque = f.f_data orelse return -errno.EBADF;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    const n: isize = vp.v_op.read(vp, f.f_offset, buf);
    if (n > 0) {
        f.f_offset += @intCast(n);
    }
    return n;
}

fn vnodeWrite(f: *file.File, buf: []const u8) isize {
    const raw: ?*anyopaque = f.f_data orelse return -errno.EBADF;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    const n: isize = vp.v_op.write(vp, f.f_offset, buf);
    if (n > 0) {
        f.f_offset += @intCast(n);
    }
    return n;
}

fn vnodeStat(f: *file.File, st: *stat.Stat) i32 {
    const raw: ?*anyopaque = f.f_data orelse return errno.EBADF;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    return fillStat(vp, st);
}

fn vnodeClose(f: *file.File) i32 {
    const raw: ?*anyopaque = f.f_data orelse return 0;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    const err: i32 = vp.v_op.close(vp, f.f_flag);
    vfs_subr.vrele(vp);
    return err;
}

/// Open `path` (relative to `start`, or absolute) and return a new open-file
/// entry, or null when the path cannot be resolved or opened. O_CREAT creates
/// the file when it does not exist.
pub fn vn_open(start: ?*vnode.Vnode, path: []const u8, flags: i32, create_mode: u16) ?*file.File {
    var resolved: ?*vnode.Vnode = vfs_lookup.nameiAt(start, path);
    if (resolved == null and (flags & fcntl.O_CREAT) != 0) {
        resolved = createNode(start, path, .vreg, create_mode, 0);
    }
    const vp: *vnode.Vnode = resolved orelse return null;

    // Character and block special files dispatch to their device driver.
    if (vp.v_type == .vchr or vp.v_type == .vblk) {
        var vap: vnode.Vattr = .{
            .type = .vnone,
            .mode = 0,
            .nlink = 0,
            .size = 0,
            .uid = 0,
            .gid = 0,
            .rdev = 0,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
        };
        const err: i32 = vp.v_op.getattr(vp, &vap);
        vfs_subr.vrele(vp);
        if (err != 0) {
            return null;
        }
        return subr_devsw.cdevOpen(vap.rdev, flags);
    }

    // Translate the access mode into the FREAD/FWRITE bits a filesystem sees.
    var mode: i32 = 0;
    const acc: i32 = flags & fcntl.O_ACCMODE;
    if (acc != fcntl.O_WRONLY) {
        mode |= file.FREAD;
    }
    if (acc != fcntl.O_RDONLY) {
        mode |= file.FWRITE;
    }

    if (vp.v_op.open(vp, mode) != 0) {
        vfs_subr.vrele(vp);
        return null;
    }

    // O_TRUNC empties the file when it is opened for writing.
    if ((flags & fcntl.O_TRUNC) != 0 and (mode & file.FWRITE) != 0) {
        _ = vp.v_op.truncate(vp, 0);
    }

    if ((flags & fcntl.O_NONBLOCK) != 0) mode |= file.FNONBLOCK;
    return kern_descrip.newFile(file.DTYPE_VNODE, mode, vp, &vnode_ops) orelse {
        vfs_subr.vrele(vp);
        return null;
    };
}

/// Create `path` with type `v_type` and permission bits `mode`, returning its
/// vnode. Used while populating the root filesystem from the boot modules
/// (paths are absolute).
pub fn vn_create(path: []const u8, v_type: vnode.Vtype, mode: u16) ?*vnode.Vnode {
    return createNode(null, path, v_type, mode, 0);
}

/// Create a device node `path` of type `v_type` with device number `rdev`.
pub fn vn_mknod(path: []const u8, v_type: vnode.Vtype, mode: u16, rdev: u64) ?*vnode.Vnode {
    return createNode(null, path, v_type, mode, rdev);
}

/// Create directory `path` (relative to `start`, or absolute) with `mode`.
pub fn vn_mkdir(start: ?*vnode.Vnode, path: []const u8, mode: u16) ?*vnode.Vnode {
    return createNode(start, path, .vdir, mode, 0);
}

/// Remove `path`. When `require_dir` is set only an empty directory may be
/// removed (rmdir); otherwise only a non-directory (unlink). Returns 0 or errno.
pub fn vn_remove(start: ?*vnode.Vnode, path: []const u8, require_dir: bool) i32 {
    var slash: ?usize = null;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            slash = i;
        }
    }
    const parent_path: []const u8 = if (slash) |s| path[0..s] else "";
    const name: []const u8 = if (slash) |s| path[s + 1 ..] else path;
    if (name.len == 0) {
        return errno.EISDIR;
    }

    const dvp: *vnode.Vnode = if (parent_path.len == 0)
        (parentDir(start, path) orelse return errno.ENOENT)
    else
        (vfs_lookup.nameiAt(start, parent_path) orelse return errno.ENOENT);
    if (dvp.v_type != .vdir) {
        return errno.ENOTDIR;
    }

    var cnp: namei.Componentname = .{
        .nameptr = name.ptr,
        .namelen = name.len,
        .nameiop = namei.DELETE,
        .flags = namei.ISLASTCN,
    };
    if (require_dir) {
        cnp.flags |= namei.REQUIREDIR;
    }
    return dvp.v_op.remove(dvp, &cnp);
}

/// Split `path` into its parent directory (looked up from `start`) and the
/// final component name.
fn splitLast(start: ?*vnode.Vnode, path: []const u8) ?struct { dvp: *vnode.Vnode, name: []const u8 } {
    var slash: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') slash = i;
    }
    const parent_path: []const u8 = if (slash) |s| path[0..s] else "";
    const name: []const u8 = if (slash) |s| path[s + 1 ..] else path;
    const dvp: *vnode.Vnode = if (parent_path.len == 0)
        (parentDir(start, path) orelse return null)
    else
        (vfs_lookup.nameiAt(start, parent_path) orelse return null);
    return .{ .dvp = dvp, .name = name };
}

/// Rename `from` to `to` (rename(2)). Returns 0 or errno.
pub fn vn_rename(fstart: ?*vnode.Vnode, from: []const u8, tstart: ?*vnode.Vnode, to: []const u8) i32 {
    const f = splitLast(fstart, from) orelse return errno.ENOENT;
    const t = splitLast(tstart, to) orelse return errno.ENOENT;
    if (f.name.len == 0 or t.name.len == 0) return errno.EINVAL;
    if (isDots(f.name) or isDots(t.name)) return errno.EINVAL;
    if (f.dvp.v_type != .vdir or t.dvp.v_type != .vdir) return errno.ENOTDIR;
    if (f.dvp.v_mount != t.dvp.v_mount) return errno.EXDEV;
    const op = f.dvp.v_op.rename orelse return errno.EROFS;
    const fcnp: namei.Componentname = .{ .nameptr = f.name.ptr, .namelen = f.name.len, .nameiop = namei.DELETE, .flags = namei.ISLASTCN };
    const tcnp: namei.Componentname = .{ .nameptr = t.name.ptr, .namelen = t.name.len, .nameiop = namei.CREATE, .flags = namei.ISLASTCN };
    return op(f.dvp, &fcnp, t.dvp, &tcnp);
}

/// Give the file `vp` the new name `path` (resolved from `start`): a hard
/// link (link(2)). Returns 0 or errno.
pub fn vn_link(vp: *vnode.Vnode, start: ?*vnode.Vnode, path: []const u8) i32 {
    if (vp.v_type == .vdir) return errno.EPERM;
    const t = splitLast(start, path) orelse return errno.ENOENT;
    if (t.name.len == 0 or isDots(t.name)) return errno.EEXIST;
    if (t.dvp.v_type != .vdir) return errno.ENOTDIR;
    if (t.dvp.v_mount != vp.v_mount) return errno.EXDEV;
    const op = t.dvp.v_op.link orelse return errno.EOPNOTSUPP;
    const cnp: namei.Componentname = .{ .nameptr = t.name.ptr, .namelen = t.name.len, .nameiop = namei.CREATE, .flags = namei.ISLASTCN };
    return op(t.dvp, vp, &cnp);
}

/// Create the symbolic link `path` (resolved from `start`) pointing at
/// `target` (symlink(2)). Returns 0 or errno.
pub fn vn_symlink(start: ?*vnode.Vnode, path: []const u8, target: []const u8, mode: u16) i32 {
    if (target.len == 0) return errno.ENOENT;
    if (vfs_lookup.nameiAtNoFollow(start, path)) |old| {
        vfs_subr.vrele(old);
        return errno.EEXIST;
    }
    const vp: *vnode.Vnode = createNode(start, path, .vlnk, mode, 0) orelse return errno.ENOENT;
    defer vfs_subr.vrele(vp);
    const n: isize = vp.v_op.write(vp, 0, target);
    if (n < 0) return @intCast(-n);
    return 0;
}

fn isDots(name: []const u8) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

/// The directory a path with no slash component starts from: the root for an
/// absolute path, `start` (or the root) otherwise.
fn parentDir(start: ?*vnode.Vnode, path: []const u8) ?*vnode.Vnode {
    if (path.len > 0 and path[0] == '/') {
        return vfs_mount.getRoot();
    }
    return start orelse vfs_mount.getRoot();
}

/// Create `path` in its parent directory, with attributes from the arguments.
fn createNode(start: ?*vnode.Vnode, path: []const u8, v_type: vnode.Vtype, mode: u16, rdev: u64) ?*vnode.Vnode {
    // Split the path into its parent directory and final component.
    var slash: ?usize = null;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            slash = i;
        }
    }
    const parent_path: []const u8 = if (slash) |s| path[0..s] else "";
    const name: []const u8 = if (slash) |s| path[s + 1 ..] else path;
    if (name.len == 0) {
        return null;
    }

    const dvp: *vnode.Vnode = if (parent_path.len == 0)
        (parentDir(start, path) orelse return null)
    else
        (vfs_lookup.nameiAt(start, parent_path) orelse return null);
    if (dvp.v_type != .vdir) {
        return null;
    }

    var cnp: namei.Componentname = .{
        .nameptr = name.ptr,
        .namelen = name.len,
        .nameiop = namei.CREATE,
        .flags = namei.ISLASTCN,
    };
    if (v_type == .vdir) {
        cnp.flags |= namei.WILLBEDIR;
    }

    const vap: vnode.Vattr = .{
        .type = v_type,
        .mode = mode,
        .nlink = 1,
        .size = 0,
        .uid = 0,
        .gid = 0,
        .rdev = rdev,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    return dvp.v_op.create(dvp, &cnp, &vap);
}
