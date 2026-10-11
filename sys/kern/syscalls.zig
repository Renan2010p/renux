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
const file: type = @import("../sys/file.zig");
const stat: type = @import("../sys/stat.zig");
const vnode: type = @import("../sys/vnode.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_fork: type = @import("kern_fork.zig");
const kern_exit: type = @import("kern_exit.zig");
const kern_exec: type = @import("kern_exec.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
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

    // The console is written through descriptors 1 and 2.
    if (fd == 1 or fd == 2) {
        const bytes: [*]const u8 = @ptrFromInt(buf);
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            cons.cnputc(bytes[i]);
        }
        return count;
    }

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

    // Descriptor 0 is the console. Wait for input, yielding the CPU (with
    // interrupts enabled) so the timer and other processes keep running.
    if (fd == 0) {
        if (count == 0) {
            return 0;
        }
        while (true) {
            arch.cpu.enable_interrupts();
            const maybe: ?u8 = cons.cngetcPoll();
            arch.cpu.disable_interrupts();
            if (maybe) |c| {
                const dst: [*]u8 = @ptrFromInt(buf);
                dst[0] = c;
                return 1;
            }
            kern_sched.yield();
        }
    }

    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;
    if ((f.f_flag & file.FREAD) == 0) {
        return error_value;
    }
    const bytes: [*]u8 = @ptrFromInt(buf);
    const n: isize = f.f_ops.read(f, bytes[0..@intCast(count)]);
    if (n < 0) {
        return error_value;
    }
    return @intCast(n);
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

    if (fd <= 2) {
        st.mode = stat.S_IFCHR | 0o620;
        st.nlink = 1;
        st.blksize = 4096;
    } else {
        const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return error_value;
        const err: i32 = f.f_ops.stat(f, &st);
        if (err != 0) {
            return error_value;
        }
    }

    const dst: [*]u8 = @ptrFromInt(statbuf);
    const src: [*]const u8 = @ptrCast(&st);
    var i: usize = 0;
    while (i < @sizeOf(stat.Stat)) : (i += 1) {
        dst[i] = src[i];
    }
    return 0;
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

fn sysExecve(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const argv_ptr: u64 = args[1];
    const envp_ptr: u64 = args[2];
    const frame = arch.trap.currentFrame() orelse return error_value;
    const path: []const u8 = userStr(path_ptr) orelse return error_value;
    return signed(kern_exec.execve(frame, path, argv_ptr, envp_ptr));
}

/// Number-to-handler table, indexed by system call number.
pub const table: [sys.MAXSYSCALL]?Handler = .{
    null, // 0
    sysExit, // 1
    sysFork, // 2
    sysRead, // 3
    sysWrite, // 4
    sysOpen, // 5
    sysClose, // 6
    sysWait, // 7
    null, // 8
    null, // 9
    null, // 10
    null, // 11
    null, // 12
    null, // 13
    null, // 14
    null, // 15
    null, // 16
    null, // 17
    null, // 18
    sysLseek, // 19
    sysGetpid, // 20
    null, // 21
    null, // 22
    null, // 23
    null, // 24
    null, // 25
    null, // 26
    null, // 27
    null, // 28
    null, // 29
    null, // 30
    null, // 31
    null, // 32
    null, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    null, // 50
    null, // 51
    null, // 52
    null, // 53
    null, // 54
    null, // 55
    null, // 56
    null, // 57
    null, // 58
    sysExecve, // 59
    null, // 60
    null, // 61
    sysFstat, // 62
    null, // 63
};
