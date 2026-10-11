// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// System call implementations.
//
// The Zig counterpart of NetBSD's generated syscalls.c: the table mapping
// system call numbers to handlers, plus the file and process calls that make
// the system usable. Descriptors 0, 1 and 2 are the console; every other open
// file lives in the process's descriptor table and reads and writes through its
// FileOps vector.

const sys: type = @import("../sys/syscall.zig");
const cons: type = @import("../dev/cons.zig");
const arch: type = @import("../arch/arch.zig");
const param: type = @import("../sys/param.zig");
const proc: type = @import("../sys/proc.zig");
const file: type = @import("../sys/file.zig");
const stat: type = @import("../sys/stat.zig");
const dirent: type = @import("../sys/dirent.zig");
const errno: type = @import("../sys/errno.zig");
const vnode: type = @import("../sys/vnode.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_fork: type = @import("kern_fork.zig");
const kern_exit: type = @import("kern_exit.zig");
const kern_exec: type = @import("kern_exec.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const prf: type = @import("subr_prf.zig");

/// A system call handler. `args` holds up to MAXARGS register arguments.
pub const Handler: type = *const fn (args: [sys.MAXARGS]u64) u64;

/// Error return value (a negative errno as unsigned).
pub const error_value: u64 = @bitCast(@as(i64, -1));

fn signed(value: i64) u64 {
    return @bitCast(value);
}

/// Read a NUL-terminated string from the calling process's address space.
fn userStr(ptr: u64) ?[]const u8 {
    if (ptr == 0) {
        return null;
    }
    const p: [*]const u8 = @ptrFromInt(ptr);
    var len: usize = 0;
    while (len < param.MAXPATHLEN) : (len += 1) {
        if (p[len] == 0) {
            return p[0..len];
        }
    }
    return null;
}

fn sysWrite(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;
    if ((f.f_flag & file.FWRITE) == 0) {
        return error_value;
    }
    const bytes: [*]u8 = @ptrFromInt(buf);
    const n: isize = f.f_ops.write(f, bytes[0..@intCast(count)]);
    if (n < 0) {
        return error_value;
    }
    return @intCast(n);
}

fn sysRead(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;
    if ((f.f_flag & file.FREAD) == 0) {
        return error_value;
    }
    const bytes: [*]u8 = @ptrFromInt(buf);
    const again: isize = -@as(isize, errno.EAGAIN);

    // A device that has nothing ready returns -EAGAIN; block until it does,
    // yielding the CPU (with interrupts enabled) so the timer and other
    // processes keep running.
    while (true) {
        arch.cpu.enable_interrupts();
        const n: isize = f.f_ops.read(f, bytes[0..@intCast(count)]);
        arch.cpu.disable_interrupts();
        if (n != again) {
            if (n < 0) {
                return error_value;
            }
            return @intCast(n);
        }
        kern_sched.yield();
    }
}

fn sysOpen(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const flags: i32 = @bitCast(@as(u32, @truncate(args[1])));

    const path: []const u8 = userStr(path_ptr) orelse return error_value;
    const f: *file.File = vfs_vnops.vn_open(path, flags) orelse return error_value;

    const fd: usize = kern_descrip.fdalloc(kern_proc.current, 3) orelse {
        _ = kern_descrip.closeFile(f);
        return error_value;
    };
    kern_descrip.fdAffix(kern_proc.current, fd, f);
    return @intCast(fd);
}

fn sysClose(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const err: i32 = kern_descrip.fd_close(kern_proc.current, @intCast(fd));
    if (err != 0) {
        return error_value;
    }
    return 0;
}

/// Size in bytes of the file behind `f`, or 0 when unknown.
fn fileSize(f: *file.File) u64 {
    if (f.f_type != file.DTYPE_VNODE) {
        return 0;
    }
    const raw: ?*anyopaque = f.f_data orelse return 0;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
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
    if (vp.v_op.getattr(vp, &vap) != 0) {
        return 0;
    }
    return vap.size;
}

fn sysLseek(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const off: i64 = @bitCast(args[1]);
    const whence: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;

    var base: i64 = 0;
    switch (whence) {
        0 => base = 0, // SEEK_SET
        1 => base = @intCast(f.f_offset), // SEEK_CUR
        2 => base = @intCast(fileSize(f)), // SEEK_END
        else => return error_value,
    }
    const target: i64 = base + off;
    if (target < 0) {
        return error_value;
    }
    f.f_offset = @intCast(target);
    return @intCast(f.f_offset);
}

fn sysFstat(args: [sys.MAXARGS]u64) u64 {
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

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;
    const err: i32 = f.f_ops.stat(f, &st);
    if (err != 0) {
        return error_value;
    }

    const dst: [*]u8 = @ptrFromInt(statbuf);
    const src: [*]const u8 = @ptrCast(&st);
    var i: usize = 0;
    while (i < @sizeOf(stat.Stat)) : (i += 1) {
        dst[i] = src[i];
    }
    return 0;
}

/// stat(2): resolve a path and copy its attributes to the caller.
fn sysStat(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const statbuf: u64 = args[1];

    const path: []const u8 = userStr(path_ptr) orelse return error_value;
    const vp: *vnode.Vnode = vfs_lookup.nameiLookup(path) orelse return error_value;

    var st: stat.Stat = undefined;
    const err: i32 = vfs_vnops.fillStat(vp, &st);
    vfs_subr.vrele(vp);
    if (err != 0) {
        return error_value;
    }

    const dst: [*]u8 = @ptrFromInt(statbuf);
    const src: [*]const u8 = @ptrCast(&st);
    var i: usize = 0;
    while (i < @sizeOf(stat.Stat)) : (i += 1) {
        dst[i] = src[i];
    }
    return 0;
}

/// getdents(2): read directory entries into the caller's buffer.
fn sysGetdents(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;
    if (f.f_type != file.DTYPE_VNODE) {
        return error_value;
    }
    const raw: ?*anyopaque = f.f_data orelse return error_value;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    if (vp.v_type != .vdir) {
        return error_value;
    }

    // Read into a kernel buffer, then copy out and advance the file offset by
    // the number of whole entries produced.
    var kbuf: [512]u8 = undefined;
    const want: usize = if (count > kbuf.len) kbuf.len else @intCast(count);
    var eofflag: bool = false;
    const n: isize = vp.v_op.readdir(vp, f.f_offset, kbuf[0..want], &eofflag);
    if (n < 0) {
        return error_value;
    }
    const nn: usize = @intCast(n);

    const dst: [*]u8 = @ptrFromInt(buf);
    var i: usize = 0;
    while (i < nn) : (i += 1) {
        dst[i] = kbuf[i];
    }

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

fn sysExit(args: [sys.MAXARGS]u64) u64 {
    const status: i32 = @bitCast(@as(u32, @truncate(args[0])));
    kern_exit.exit(status);
}

fn sysFork(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    const frame = arch.trap.currentFrame() orelse return error_value;
    return signed(kern_fork.fork(frame));
}

fn sysWait(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    var status: i32 = 0;
    return signed(kern_exit.wait(&status));
}

fn sysGetpid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.pid);
}

fn sysDup2(args: [sys.MAXARGS]u64) u64 {
    const oldfd: u64 = args[0];
    const newfd: u64 = args[1];
    if (oldfd >= proc.NFILE or newfd >= proc.NFILE) {
        return error_value;
    }
    const p: *proc.Proc = kern_proc.current;
    const f: *file.File = kern_descrip.fdGetfile(p, @intCast(oldfd)) orelse return error_value;
    if (oldfd == newfd) {
        return newfd;
    }
    if (kern_descrip.fdGetfile(p, @intCast(newfd)) != null) {
        _ = kern_descrip.fd_close(p, @intCast(newfd));
    }
    f.f_count += 1;
    kern_descrip.fdAffix(p, @intCast(newfd), f);
    return newfd;
}

fn sysExecve(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const argv_ptr: u64 = args[1];
    const envp_ptr: u64 = args[2];
    const frame = arch.trap.currentFrame() orelse return error_value;
    const path: []const u8 = userStr(path_ptr) orelse return error_value;
    return signed(kern_exec.execve(frame, path, argv_ptr, envp_ptr));
}

/// One entry of the dispatch table: a system call number and its handler.
const Entry: type = struct {
    num: usize,
    handler: Handler,
};

/// The implemented system calls. NetBSD generates this from syscalls.master;
/// ZenBSD lists what it has and builds the table from it.
const syscall_list: []const Entry = &.{
    .{ .num = sys.SYS_exit, .handler = sysExit },
    .{ .num = sys.SYS_fork, .handler = sysFork },
    .{ .num = sys.SYS_read, .handler = sysRead },
    .{ .num = sys.SYS_write, .handler = sysWrite },
    .{ .num = sys.SYS_open, .handler = sysOpen },
    .{ .num = sys.SYS_close, .handler = sysClose },
    .{ .num = sys.SYS_wait4, .handler = sysWait },
    .{ .num = sys.SYS_lseek, .handler = sysLseek },
    .{ .num = sys.SYS_getpid, .handler = sysGetpid },
    .{ .num = sys.SYS_dup2, .handler = sysDup2 },
    .{ .num = sys.SYS_execve, .handler = sysExecve },
    .{ .num = sys.SYS_fstat, .handler = sysFstat },
    .{ .num = sys.SYS_stat, .handler = sysStat },
    .{ .num = sys.SYS_getdents, .handler = sysGetdents },
};

/// Number-to-handler table, indexed by system call number.
pub const table: [sys.MAXSYSCALL]?Handler = blk: {
    var t: [sys.MAXSYSCALL]?Handler = undefined;
    for (&t) |*slot| {
        slot.* = null;
    }
    for (syscall_list) |entry| {
        t[entry.num] = entry.handler;
    }
    break :blk t;
};
