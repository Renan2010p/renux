// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// VFS system calls.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_syscalls.c, reduced to
// the calls that operate on pathnames: open, the stat family, getdents, and the
// directory/chdir calls. Each resolves its path against the process's working
// directory before reaching the VFS layer.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const param: type = @import("../sys/param.zig");
const file: type = @import("../sys/file.zig");
const stat: type = @import("../sys/stat.zig");
const dirent: type = @import("../sys/dirent.zig");
const proc: type = @import("../sys/proc.zig");
const vnode: type = @import("../sys/vnode.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kern_time: type = @import("kern_time.zig");
const kmem: type = @import("subr_kmem.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const subr_syscall: type = @import("subr_syscall.zig");

/// fsync(2)/fdatasync(2): Renux has no disk cache to flush yet, so both are
/// successful no-ops. (nano calls fsync after a save and errors out otherwise.)
pub fn sysFsync(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

/// ftruncate(2): change the size of the file behind descriptor `fd`.
pub fn sysFtruncate(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const length: u64 = args[1];
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;
    if (f.f_type != file.DTYPE_VNODE) {
        return sys.ERROR;
    }
    const raw: ?*anyopaque = f.f_data orelse return sys.ERROR;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    const err: i32 = vp.v_op.truncate(vp, length);
    if (err != 0) {
        return sys.signed(-err);
    }
    return 0;
}

/// truncate(2): change the size of the named file.
pub fn sysTruncate(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const length: u64 = args[1];
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.ERROR;
    const vp: *vnode.Vnode = vfs_lookup.nameiLookup(path) orelse return sys.signed(-errno.ENOENT);
    const err: i32 = vp.v_op.truncate(vp, length);
    if (err != 0) {
        return sys.signed(-err);
    }
    return 0;
}

/// open(2): resolve `path` relative to the working directory and return a
/// descriptor.
pub fn sysOpen(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const flags: i32 = @bitCast(@as(u32, @truncate(args[1])));

    const p: *proc.Proc = kern_proc.current;
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const mode: u16 = @truncate(args[2] & 0o777 & ~@as(u64, p.cmask));
    const f: *file.File = vfs_vnops.vn_open(p.cwd, path, flags, mode) orelse return sys.signed(-errno.ENOENT);

    // POSIX: the lowest free descriptor (programs that close 0-2 and reopen
    // the terminal rely on getting 0 back).
    const fd: usize = kern_descrip.fdalloc(p, 0) orelse {
        _ = kern_descrip.closeFile(f);
        return sys.signed(-errno.EMFILE);
    };
    kern_descrip.fdAffix(p, fd, f);
    recordDirPath(p, f, path);
    const O_CLOEXEC: i32 = 0x00100000;
    kern_descrip.fdSetCloexec(p, fd, (flags & O_CLOEXEC) != 0);
    return @intCast(fd);
}

/// stat(2): resolve `path` and copy its attributes to the caller.
pub fn sysStat(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const statbuf: u64 = args[1];

    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const vp: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, path) orelse return sys.signed(-errno.ENOENT);

    var st: stat.Stat = undefined;
    const err: i32 = vfs_vnops.fillStat(vp, &st);
    vfs_subr.vrele(vp);
    if (err != 0) {
        return sys.signed(-err);
    }
    copyOut(statbuf, @ptrCast(&st), @sizeOf(stat.Stat));
    return 0;
}

/// fstat(2): copy the attributes of an open file to the caller.
pub fn sysFstat(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const statbuf: u64 = args[1];

    var st: stat.Stat = .{
        .dev = 0,
        .ino = 0,
        .nlink = 0,
        .mode = 0,
        .padding0 = 0,
        .uid = 0,
        .gid = 0,
        .padding1 = 0,
        .rdev = 0,
        .atim = .{ .sec = 0, .nsec = 0 },
        .mtim = .{ .sec = 0, .nsec = 0 },
        .ctim = .{ .sec = 0, .nsec = 0 },
        .size = 0,
        .blocks = 0,
        .blksize = 0,
        .flags = 0,
        .gen = 0,
        .lspare = 0,
        .birthtim = .{ .sec = 0, .nsec = 0 },
    };
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;
    const err: i32 = f.f_ops.stat(f, &st);
    if (err != 0) {
        return sys.ERROR;
    }
    copyOut(statbuf, @ptrCast(&st), @sizeOf(stat.Stat));
    return 0;
}

/// fstatat(2): `fstatat(fd, path, buf, flag)`. A NULL or empty path stats the
/// descriptor itself, which is how libc implements fstat(3).
pub fn sysFstatat(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const path_ptr: u64 = args[1];
    const statbuf: u64 = args[2];

    if (path_ptr == 0) {
        return sysFstat(.{ fd, statbuf, 0, 0, 0, 0 });
    }
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    if (path.len == 0) {
        return sysFstat(.{ fd, statbuf, 0, 0, 0, 0 });
    }
    // AT_SYMLINK_NOFOLLOW: stat a symbolic link itself (lstat(2)).
    const vp: *vnode.Vnode = (if ((args[3] & AT_SYMLINK_NOFOLLOW) != 0)
        vfs_lookup.nameiAtNoFollow(kern_proc.current.cwd, path)
    else
        vfs_lookup.nameiAt(kern_proc.current.cwd, path)) orelse return sys.signed(-errno.ENOENT);
    var st: stat.Stat = undefined;
    const e: i32 = vfs_vnops.fillStat(vp, &st);
    vfs_subr.vrele(vp);
    if (e != 0) {
        return sys.signed(-e);
    }
    copyOut(statbuf, @ptrCast(&st), @sizeOf(stat.Stat));
    return 0;
}

/// getdents(2): read directory entries into the caller's buffer.
pub fn sysGetdents(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;
    if (f.f_type != file.DTYPE_VNODE) {
        return sys.ERROR;
    }
    const raw: ?*anyopaque = f.f_data orelse return sys.ERROR;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    if (vp.v_type != .vdir) {
        return sys.ERROR;
    }

    var kbuf: [512]u8 = undefined;
    const want: usize = if (count > kbuf.len) kbuf.len else @intCast(count);
    var eofflag: bool = false;
    const n: isize = vp.v_op.readdir(vp, f.f_offset, kbuf[0..want], &eofflag);
    if (n < 0) {
        return sys.ERROR;
    }
    const nn: usize = @intCast(n);
    copyOut(buf, &kbuf, nn);

    // Advance the file offset by the number of whole entries produced.
    var off: u64 = f.f_offset;
    var j: usize = 0;
    while (j + @sizeOf(dirent.Dirent) <= nn) {
        const rec: *const dirent.Dirent = @ptrCast(@alignCast(&kbuf[j]));
        if (rec.reclen == 0) {
            break;
        }
        off += 1;
        j += rec.reclen;
    }
    f.f_offset = off;
    return nn;
}

/// chdir(2): change the working directory and remember its path.
/// Remember the absolute path of a directory opened as `f`, for fchdir(2).
fn recordDirPath(p: *proc.Proc, f: *file.File, path: []const u8) void {
    if (f.f_type != file.DTYPE_VNODE) return;
    const raw: *anyopaque = f.f_data orelse return;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    if (vp.v_type != .vdir) return;
    const buf: [*]u8 = @ptrCast(kmem.alloc(param.MAXPATHLEN) orelse return);
    const n: usize = normPath(p.cwd_path[0..p.cwd_len], path, buf[0..param.MAXPATHLEN]) orelse {
        kmem.free(@ptrCast(buf));
        return;
    };
    f.f_path = buf;
    f.f_pathlen = n;
}

/// fchdir(2): make the directory open as `fd` the working directory.
pub fn sysFchdir(args: [sys.MAXARGS]u64) u64 {
    const p: *proc.Proc = kern_proc.current;
    const f: *file.File = kern_descrip.fdGetfile(p, @intCast(args[0])) orelse return sys.signed(-errno.EBADF);
    if (f.f_type != file.DTYPE_VNODE) return sys.signed(-errno.ENOTDIR);
    const raw: *anyopaque = f.f_data orelse return sys.signed(-errno.EBADF);
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    if (vp.v_type != .vdir) return sys.signed(-errno.ENOTDIR);
    const path: [*]u8 = f.f_path orelse return sys.signed(-errno.ENOENT);
    @memcpy(p.cwd_path[0..f.f_pathlen], path[0..f.f_pathlen]);
    p.cwd_len = f.f_pathlen;
    vfs_subr.vref(vp);
    if (p.cwd) |old| vfs_subr.vrele(old);
    p.cwd = vp;
    return 0;
}

pub fn sysChdir(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);

    const p: *proc.Proc = kern_proc.current;
    const vp: *vnode.Vnode = vfs_lookup.nameiAt(p.cwd, path) orelse return sys.signed(-errno.ENOENT);
    if (vp.v_type != .vdir) {
        vfs_subr.vrele(vp);
        return sys.signed(-errno.ENOTDIR);
    }

    const newlen: usize = normPath(p.cwd_path[0..p.cwd_len], path, &p.cwd_path) orelse {
        vfs_subr.vrele(vp);
        return sys.signed(-errno.ENAMETOOLONG);
    };
    p.cwd_len = newlen;

    if (p.cwd) |old| {
        vfs_subr.vrele(old);
    }
    p.cwd = vp;
    return 0;
}

/// mkdir(2): create a directory.
pub fn sysMkdir(args: [sys.MAXARGS]u64) u64 {
    return mkdirCommon(args[0], args[1]);
}

/// mkdirat(2): `mkdirat(fd, path, mode)`.
pub fn sysMkdirat(args: [sys.MAXARGS]u64) u64 {
    return mkdirCommon(args[1], args[2]);
}

fn mkdirCommon(path_ptr: u64, mode_arg: u64) u64 {
    const mode: u16 = @truncate(mode_arg & 0o777 & ~@as(u64, kern_proc.current.cmask));
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const cwd = kern_proc.current.cwd;
    // Tell an existing name (EEXIST) from a missing parent (ENOENT).
    if (vfs_lookup.nameiAtNoFollow(cwd, path)) |old| {
        vfs_subr.vrele(old);
        return sys.signed(-errno.EEXIST);
    }
    const vp: *vnode.Vnode = vfs_vnops.vn_mkdir(cwd, path, mode) orelse return sys.signed(-errno.ENOENT);
    vfs_subr.vrele(vp);
    return 0;
}

/// unlinkat(2): `unlinkat(fd, path, flag)`; AT_REMOVEDIR removes a directory.
pub fn sysUnlinkat(args: [sys.MAXARGS]u64) u64 {
    const AT_REMOVEDIR: u64 = 0x800;
    const path: []const u8 = subr_syscall.userStr(args[1]) orelse return sys.signed(-errno.EFAULT);
    const err: i32 = vfs_vnops.vn_remove(kern_proc.current.cwd, path, (args[2] & AT_REMOVEDIR) != 0);
    return if (err == 0) 0 else sys.signed(-err);
}

/// rmdir(2): remove an empty directory.
pub fn sysRmdir(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const err: i32 = vfs_vnops.vn_remove(kern_proc.current.cwd, path, true);
    if (err != 0) {
        return sys.signed(-err);
    }
    return 0;
}

/// unlink(2): remove a non-directory.
pub fn sysUnlink(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const err: i32 = vfs_vnops.vn_remove(kern_proc.current.cwd, path, false);
    if (err != 0) {
        return sys.signed(-err);
    }
    return 0;
}

/// access(2): report whether the calling process can access `path`. Only the
/// path's existence is checked (permissions are not modelled yet).
pub fn sysAccess(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const vp: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, path) orelse return sys.signed(-errno.ENOENT);
    vfs_subr.vrele(vp);
    return 0;
}

/// faccessat(2): like access(2); the descriptor is only used when the path is
/// empty.
pub fn sysFaccessat(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[1];
    if (path_ptr == 0) {
        return 0;
    }
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    if (path.len == 0) {
        return 0;
    }
    const vp: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, path) orelse return sys.signed(-errno.ENOENT);
    vfs_subr.vrele(vp);
    return 0;
}

/// readlink(2): `readlink(path, buf, bufsize)`, the target of a symbolic link,
/// not NUL-terminated.
pub fn sysReadlink(args: [sys.MAXARGS]u64) u64 {
    return readlinkCommon(args[0], args[1], args[2]);
}

/// readlinkat(2): `readlinkat(fd, path, buf, bufsize)`; relative paths are
/// resolved from the current directory, as elsewhere.
pub fn sysReadlinkat(args: [sys.MAXARGS]u64) u64 {
    return readlinkCommon(args[1], args[2], args[3]);
}

fn readlinkCommon(path_ptr: u64, buf: u64, bufsize: u64) u64 {
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const vp: *vnode.Vnode = vfs_lookup.nameiAtNoFollow(kern_proc.current.cwd, path) orelse return sys.signed(-errno.ENOENT);
    defer vfs_subr.vrele(vp);
    if (vp.v_type != .vlnk) {
        return sys.signed(-errno.EINVAL);
    }
    var lbuf: [param.MAXPATHLEN]u8 = undefined;
    const n: isize = vp.v_op.read(vp, 0, &lbuf);
    if (n < 0) {
        return sys.signed(-errno.EIO);
    }
    const len: usize = @min(@as(usize, @intCast(n)), bufsize);
    copyOut(buf, &lbuf, len);
    return len;
}

/// openat(2): open a path relative to a directory descriptor. Only the current
/// directory (AT_FDCWD) and absolute paths are resolved, as elsewhere.
pub fn sysOpenat(args: [sys.MAXARGS]u64) u64 {
    const shifted: [sys.MAXARGS]u64 = .{ args[1], args[2], args[3], 0, 0, 0 };
    return sysOpen(shifted);
}

/// Copy `len` bytes of kernel memory to the caller's address `dst`.
fn copyOut(dst: u64, src: [*]const u8, len: usize) void {
    const d: [*]u8 = @ptrFromInt(dst);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        d[i] = src[i];
    }
}

/// Build a normalised absolute path from `base` (already absolute) and `path`
/// into `out`; returns its length or null when it would not fit.
fn normPath(base: []const u8, path: []const u8, out: []u8) ?usize {
    var len: usize = 0;

    // A relative path is taken from the base directory.
    if (!(path.len > 0 and path[0] == '/')) {
        if (base.len > out.len) {
            return null;
        }
        var b: usize = 0;
        while (b < base.len) : (b += 1) {
            out[b] = base[b];
        }
        len = base.len;
    }

    var i: usize = 0;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') : (i += 1) {}
        const start: usize = i;
        while (i < path.len and path[i] != '/') : (i += 1) {}
        const comp: []const u8 = path[start..i];
        if (comp.len == 0 or (comp.len == 1 and comp[0] == '.')) {
            continue;
        }
        if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {
            while (len > 0 and out[len - 1] != '/') : (len -= 1) {}
            if (len > 0) {
                len -= 1; // drop the separating slash
            }
            continue;
        }
        if (len == 0 or out[len - 1] != '/') {
            if (len + 1 > out.len) {
                return null;
            }
            out[len] = '/';
            len += 1;
        }
        if (len + comp.len > out.len) {
            return null;
        }
        var k: usize = 0;
        while (k < comp.len) : (k += 1) {
            out[len] = comp[k];
            len += 1;
        }
    }

    if (len == 0) {
        out[0] = '/';
        len = 1;
    }
    return len;
}

// -- attributes: chmod, chown, chflags, utimes -----------------------------------
//
// FreeBSD's sys/kern/vfs_syscalls.c. The *at variants resolve relative paths
// from the current directory, as elsewhere; AT_SYMLINK_NOFOLLOW acts on a
// symbolic link itself.

const AT_SYMLINK_NOFOLLOW: u64 = 0x200;

/// The vnode behind descriptor `fd`, referenced, or null.
fn fdVnode(fd: u64) ?*vnode.Vnode {
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return null;
    if (f.f_type != file.DTYPE_VNODE) return null;
    const raw: *anyopaque = f.f_data orelse return null;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    vfs_subr.vref(vp);
    return vp;
}

/// The vnode for a user path, referenced, or null.
fn pathVnode(path_ptr: u64, follow: bool) ?*vnode.Vnode {
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return null;
    const cwd = kern_proc.current.cwd;
    return if (follow) vfs_lookup.nameiAt(cwd, path) else vfs_lookup.nameiAtNoFollow(cwd, path);
}

/// Apply `sa` to `vp` (releasing it), after the permission check: only the
/// owner or root may change the mode or times; only root may change owners.
fn setattrVp(vp_opt: ?*vnode.Vnode, sa: vnode.Setattr) u64 {
    const vp: *vnode.Vnode = vp_opt orelse return sys.signed(-errno.ENOENT);
    defer vfs_subr.vrele(vp);
    var cur: vnode.Vattr = undefined;
    if (vp.v_op.getattr(vp, &cur) != 0) return sys.signed(-errno.EIO);
    const p = kern_proc.current;
    if (p.euid != 0) {
        if (sa.uid != null or sa.gid != null) return sys.signed(-errno.EPERM);
        if (p.euid != cur.uid) return sys.signed(-errno.EPERM);
    }
    const setattr = vp.v_op.setattr orelse return sys.signed(-errno.EROFS);
    const e: i32 = setattr(vp, &sa);
    return if (e == 0) 0 else sys.signed(-e);
}

fn modeArg(a: u64) vnode.Setattr {
    return .{ .mode = @truncate(a & 0o7777) };
}

/// An owner argument: -1 (as a 32-bit id) leaves the id unchanged.
fn ownerArg(u: u64, g: u64) vnode.Setattr {
    const uu: u32 = @truncate(u);
    const gg: u32 = @truncate(g);
    return .{
        .uid = if (uu == 0xffffffff) null else uu,
        .gid = if (gg == 0xffffffff) null else gg,
    };
}

pub fn sysChmod(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[0], true), modeArg(args[1]));
}

pub fn sysFchmod(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(fdVnode(args[0]), modeArg(args[1]));
}

pub fn sysLchmod(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[0], false), modeArg(args[1]));
}

pub fn sysFchmodat(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[1], (args[3] & AT_SYMLINK_NOFOLLOW) == 0), modeArg(args[2]));
}

pub fn sysChown(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[0], true), ownerArg(args[1], args[2]));
}

pub fn sysFchown(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(fdVnode(args[0]), ownerArg(args[1], args[2]));
}

pub fn sysLchown(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[0], false), ownerArg(args[1], args[2]));
}

pub fn sysFchownat(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[1], (args[4] & AT_SYMLINK_NOFOLLOW) == 0), ownerArg(args[2], args[3]));
}

/// chflags(2) family: Renux files have no flags (UF_*/SF_*). Clearing them
/// all succeeds, as on a filesystem without flag support; setting one is
/// refused like FreeBSD does on such filesystems.
fn flagsCommon(vp_opt: ?*vnode.Vnode, flags: u64) u64 {
    const vp: *vnode.Vnode = vp_opt orelse return sys.signed(-errno.ENOENT);
    vfs_subr.vrele(vp);
    return if (flags == 0) 0 else sys.signed(-errno.EOPNOTSUPP);
}

pub fn sysChflags(args: [sys.MAXARGS]u64) u64 {
    return flagsCommon(pathVnode(args[0], true), args[1]);
}

pub fn sysLchflags(args: [sys.MAXARGS]u64) u64 {
    return flagsCommon(pathVnode(args[0], false), args[1]);
}

pub fn sysFchflags(args: [sys.MAXARGS]u64) u64 {
    return flagsCommon(fdVnode(args[0]), args[1]);
}

pub fn sysChflagsat(args: [sys.MAXARGS]u64) u64 {
    return flagsCommon(pathVnode(args[1], (args[3] & AT_SYMLINK_NOFOLLOW) == 0), args[2]);
}

/// Times from a struct timespec[2] (access, modification): NULL means now;
/// UTIME_NOW and UTIME_OMIT are FreeBSD's special nanosecond values.
fn timesArg(ts_ptr: u64) vnode.Setattr {
    const now: i64 = @intCast(kern_time.now());
    if (ts_ptr == 0) return .{ .atime = now, .mtime = now };
    const UTIME_NOW: i64 = -1;
    const UTIME_OMIT: i64 = -2;
    const ts: [*]align(1) const kern_time.Timespec = @ptrFromInt(ts_ptr);
    var sa: vnode.Setattr = .{};
    if (ts[0].tv_nsec != UTIME_OMIT) sa.atime = if (ts[0].tv_nsec == UTIME_NOW) now else ts[0].tv_sec;
    if (ts[1].tv_nsec != UTIME_OMIT) sa.mtime = if (ts[1].tv_nsec == UTIME_NOW) now else ts[1].tv_sec;
    return sa;
}

/// utimensat(2): `utimensat(fd, path, times, flag)`.
pub fn sysUtimensat(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(pathVnode(args[1], (args[3] & AT_SYMLINK_NOFOLLOW) == 0), timesArg(args[2]));
}

/// futimens(2): `futimens(fd, times)`.
pub fn sysFutimens(args: [sys.MAXARGS]u64) u64 {
    return setattrVp(fdVnode(args[0]), timesArg(args[1]));
}
