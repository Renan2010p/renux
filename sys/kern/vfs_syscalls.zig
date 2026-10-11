// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
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
const vfs_vnops: type = @import("vfs_vnops.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const subr_syscall: type = @import("subr_syscall.zig");

/// open(2): resolve `path` relative to the working directory and return a
/// descriptor.
pub fn sysOpen(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const flags: i32 = @bitCast(@as(u32, @truncate(args[1])));

    const p: *proc.Proc = kern_proc.current;
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const mode: u16 = @truncate(args[2] & 0o777);
    const f: *file.File = vfs_vnops.vn_open(p.cwd, path, flags, mode) orelse return sys.signed(-errno.ENOENT);

    const fd: usize = kern_descrip.fdalloc(p, 3) orelse {
        _ = kern_descrip.closeFile(f);
        return sys.signed(-errno.ENFILE);
    };
    kern_descrip.fdAffix(p, fd, f);
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
        .mode = 0,
        .nlink = 0,
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .size = 0,
        .blksize = 0,
        .blocks = 0,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return sys.ERROR;
    const err: i32 = f.f_ops.stat(f, &st);
    if (err != 0) {
        return sys.ERROR;
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
    const path_ptr: u64 = args[0];
    const mode: u16 = @truncate(args[1] & 0o777);
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.signed(-errno.EFAULT);
    const vp: *vnode.Vnode = vfs_vnops.vn_mkdir(kern_proc.current.cwd, path, mode) orelse return sys.signed(-errno.EEXIST);
    vfs_subr.vrele(vp);
    return 0;
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
