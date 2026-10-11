// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// System call dispatch table.
//
// This is the Zig counterpart of NetBSD's generated syscalls.c: the table that
// maps system call numbers to handlers. As in NetBSD, the handlers themselves
// live with their subsystems (vfs_syscalls.zig, sys_generic.zig, kern_*.zig);
// the process and descriptor calls whose implementations are small enough stay
// here with the table.

const sys: type = @import("../sys/syscall.zig");
const arch: type = @import("../arch/arch.zig");
const proc: type = @import("../sys/proc.zig");
const file: type = @import("../sys/file.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_fork: type = @import("kern_fork.zig");
const kern_exit: type = @import("kern_exit.zig");
const kern_exec: type = @import("kern_exec.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_time: type = @import("kern_time.zig");
const kern_prot: type = @import("kern_prot.zig");
const vfs_syscalls: type = @import("vfs_syscalls.zig");
const sys_generic: type = @import("sys_generic.zig");
const vfs_getcwd: type = @import("vfs_getcwd.zig");
const uvm_mmap: type = @import("../uvm/uvm_mmap.zig");
const subr_syscall: type = @import("subr_syscall.zig");

/// A system call handler. `args` holds up to MAXARGS register arguments.
pub const Handler: type = *const fn (args: [sys.MAXARGS]u64) u64;

fn sysExit(args: [sys.MAXARGS]u64) u64 {
    const status: i32 = @bitCast(@as(u32, @truncate(args[0])));
    kern_exit.exit(status);
}

fn sysFork(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    const frame = arch.trap.currentFrame() orelse return sys.ERROR;
    return sys.signed(kern_fork.fork(frame));
}

fn sysWait(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    var status: i32 = 0;
    return sys.signed(kern_exit.wait(&status));
}

fn sysGetpid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.pid);
}

fn sysClose(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const err: i32 = kern_descrip.fd_close(kern_proc.current, @intCast(fd));
    if (err != 0) {
        return sys.ERROR;
    }
    return 0;
}

fn sysDup2(args: [sys.MAXARGS]u64) u64 {
    const oldfd: u64 = args[0];
    const newfd: u64 = args[1];
    if (oldfd >= proc.NFILE or newfd >= proc.NFILE) {
        return sys.ERROR;
    }
    const p: *proc.Proc = kern_proc.current;
    const f: *file.File = kern_descrip.fdGetfile(p, @intCast(oldfd)) orelse return sys.ERROR;
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
    const frame = arch.trap.currentFrame() orelse return sys.ERROR;
    const path: []const u8 = subr_syscall.userStr(path_ptr) orelse return sys.ERROR;
    return sys.signed(kern_exec.execve(frame, path, argv_ptr, envp_ptr));
}

/// One entry of the dispatch table: a system call number and its handler.
const Entry: type = struct {
    num: usize,
    handler: Handler,
};

/// The implemented system calls. NetBSD generates this from syscalls.master;
/// Renux lists what it has and builds the table from it.
const syscall_list: []const Entry = &.{
    .{ .num = sys.SYS_exit, .handler = sysExit },
    .{ .num = sys.SYS_fork, .handler = sysFork },
    .{ .num = sys.SYS_read, .handler = sys_generic.sysRead },
    .{ .num = sys.SYS_write, .handler = sys_generic.sysWrite },
    .{ .num = sys.SYS_open, .handler = vfs_syscalls.sysOpen },
    .{ .num = sys.SYS_close, .handler = sysClose },
    .{ .num = sys.SYS_wait4, .handler = sysWait },
    .{ .num = sys.SYS_unlink, .handler = vfs_syscalls.sysUnlink },
    .{ .num = sys.SYS_chdir, .handler = vfs_syscalls.sysChdir },
    .{ .num = sys.SYS_brk, .handler = uvm_mmap.sysBrk },
    .{ .num = sys.SYS_mmap, .handler = uvm_mmap.sysMmap },
    .{ .num = sys.SYS_munmap, .handler = uvm_mmap.sysMunmap },
    .{ .num = sys.SYS_gettimeofday, .handler = kern_time.sysGettimeofday },
    .{ .num = sys.SYS_lseek, .handler = sys_generic.sysLseek },
    .{ .num = sys.SYS_getpid, .handler = sysGetpid },
    .{ .num = sys.SYS_getuid, .handler = kern_prot.sysGetuid },
    .{ .num = sys.SYS_setuid, .handler = kern_prot.sysSetuid },
    .{ .num = sys.SYS_dup2, .handler = sysDup2 },
    .{ .num = sys.SYS_ioctl, .handler = sys_generic.sysIoctl },
    .{ .num = sys.SYS_kill, .handler = kern_signal.sysKill },
    .{ .num = sys.SYS_sigaction, .handler = kern_signal.sysSigaction },
    .{ .num = sys.SYS_sigreturn, .handler = kern_signal.sysSigreturn },
    .{ .num = sys.SYS_execve, .handler = sysExecve },
    .{ .num = sys.SYS_fstat, .handler = vfs_syscalls.sysFstat },
    .{ .num = sys.SYS_mkdir, .handler = vfs_syscalls.sysMkdir },
    .{ .num = sys.SYS_rmdir, .handler = vfs_syscalls.sysRmdir },
    .{ .num = sys.SYS_stat, .handler = vfs_syscalls.sysStat },
    .{ .num = sys.SYS_getdents, .handler = vfs_syscalls.sysGetdents },
    .{ .num = sys.SYS_getcwd, .handler = vfs_getcwd.sysGetcwd },
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
