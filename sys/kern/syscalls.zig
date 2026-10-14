// SPDX-License-Identifier: GPL-2.0-or-later
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
const errno: type = @import("../sys/errno.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_context: type = @import("kern_context.zig");
const vfs_mount: type = @import("vfs_mount.zig");
const kern_shutdown: type = @import("kern_shutdown.zig");
const kern_time: type = @import("kern_time.zig");
const kern_prot: type = @import("kern_prot.zig");
const kern_sysctl: type = @import("kern_sysctl.zig");
const kern_resource: type = @import("kern_resource.zig");
const vfs_syscalls: type = @import("vfs_syscalls.zig");
const arch_sysarch: type = @import("../arch/arch.zig");
const sys_generic: type = @import("sys_generic.zig");
const sys_poll: type = @import("sys_poll.zig");
const vfs_getcwd: type = @import("vfs_getcwd.zig");
const vm_mmap: type = @import("../vm/vm_mmap.zig");
const subr_syscall: type = @import("subr_syscall.zig");
const kern_cpuset: type = @import("kern_cpuset.zig");
const kern_thr: type = @import("kern_thr.zig");
const sys_pipe: type = @import("sys_pipe.zig");
const sys_getrandom: type = @import("sys_getrandom.zig");
const kern_lockf: type = @import("kern_lockf.zig");
const kern_umtx: type = @import("kern_umtx.zig");

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

/// wait4(2): `wait4(pid, status, options, rusage)`.
fn sysWait(args: [sys.MAXARGS]u64) u64 {
    const sel: i32 = @bitCast(@as(u32, @truncate(args[0])));
    const status_ptr: u64 = args[1];
    const options: u32 = @truncate(args[2]);

    var status: i32 = 0;
    const pid: i32 = kern_exit.wait(sel, &status, options);
    if (pid > 0 and status_ptr != 0) {
        const dst: *align(1) i32 = @ptrFromInt(status_ptr);
        dst.* = status;
    }
    return sys.signed(pid);
}

fn sysGetpid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.pid);
}

/// A system call whose effect Renux does not model yet but which callers treat
/// as harmless: report success.
fn sysOk(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

/// getppid(2): init's parent is init; a child's parent is its recorded parent.
fn sysGetppid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    if (kern_proc.current.parent) |p| {
        return @intCast(p.pid);
    }
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

/// close_range(2): close (or, with CLOSE_RANGE_CLOEXEC, mark close-on-exec)
/// every descriptor from `lowfd` to `highfd`.
fn sysCloseRange(args: [sys.MAXARGS]u64) u64 {
    const CLOSE_RANGE_CLOEXEC: u64 = 1 << 2;
    const p = kern_proc.current;
    if (args[0] > args[1]) return sys.signed(-errno.EINVAL);
    var fd: u64 = args[0];
    while (fd <= args[1] and fd < proc.NFILE) : (fd += 1) {
        if (p.fds[@intCast(fd)] == null) continue;
        if ((args[2] & CLOSE_RANGE_CLOEXEC) != 0) {
            kern_descrip.fdSetCloexec(p, @intCast(fd), true);
        } else {
            _ = kern_descrip.fd_close(p, @intCast(fd));
        }
    }
    return 0;
}

/// getdtablesize(2): the size of the descriptor table (RLIMIT_NOFILE).
fn sysGetdtablesize(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.rlimits[8].cur);
}

/// dup(2): the lowest free descriptor, sharing the open file.
fn sysDup(args: [sys.MAXARGS]u64) u64 {
    return sys.signed(kern_descrip.fdDup(kern_proc.current, @intCast(args[0]), 0, false));
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
    // vfork(2) as fork: the child may only exec or _exit, which copying the
    // address space satisfies (the parent is simply not suspended).
    .{ .num = sys.SYS_vfork, .handler = sysFork },
    .{ .num = sys.SYS_read, .handler = sys_generic.sysRead },
    .{ .num = sys.SYS_write, .handler = sys_generic.sysWrite },
    .{ .num = sys.SYS_open, .handler = vfs_syscalls.sysOpen },
    .{ .num = sys.SYS_close, .handler = sysClose },
    .{ .num = sys.SYS_wait4, .handler = sysWait },
    .{ .num = sys.SYS_unlink, .handler = vfs_syscalls.sysUnlink },
    .{ .num = sys.SYS_chdir, .handler = vfs_syscalls.sysChdir },
    .{ .num = sys.SYS_brk, .handler = vm_mmap.sysBrk },
    .{ .num = sys.SYS_mmap, .handler = vm_mmap.sysMmap },
    .{ .num = sys.SYS_munmap, .handler = vm_mmap.sysMunmap },
    .{ .num = sys.SYS_mprotect, .handler = vm_mmap.sysMprotect },
    .{ .num = sys.SYS_issetugid, .handler = kern_prot.sysIssetugid },
    .{ .num = sys.SYS_sysarch, .handler = arch_sysarch.sysarch.sysSysarch },
    .{ .num = sys.SYS_sigprocmask, .handler = kern_signal.sysSigprocmask },
    .{ .num = sys.SYS_gettimeofday, .handler = kern_time.sysGettimeofday },
    .{ .num = sys.SYS_lseek, .handler = sys_generic.sysLseek },
    .{ .num = sys.SYS_getpid, .handler = sysGetpid },
    .{ .num = sys.SYS_getuid, .handler = kern_prot.sysGetuid },
    .{ .num = sys.SYS_setuid, .handler = kern_prot.sysSetuid },
    .{ .num = sys.SYS_dup2, .handler = sysDup2 },
    .{ .num = sys.SYS_dup, .handler = sysDup },
    .{ .num = sys.SYS_ioctl, .handler = sys_generic.sysIoctl },
    .{ .num = sys.SYS_kill, .handler = kern_signal.sysKill },
    .{ .num = sys.SYS_sigaction, .handler = kern_signal.sysSigaction },
    .{ .num = sys.SYS_sigreturn, .handler = arch.exec_machdep.sysSigreturn },
    .{ .num = sys.SYS_sigsuspend, .handler = kern_signal.sysSigsuspend },
    .{ .num = sys.SYS_sync, .handler = vfs_mount.sysSync },
    .{ .num = sys.SYS_reboot, .handler = kern_shutdown.sysReboot },
    .{ .num = sys.SYS_link, .handler = vfs_syscalls.sysLink },
    .{ .num = sys.SYS_linkat, .handler = vfs_syscalls.sysLinkat },
    .{ .num = sys.SYS_symlink, .handler = vfs_syscalls.sysSymlink },
    .{ .num = sys.SYS_symlinkat, .handler = vfs_syscalls.sysSymlinkat },
    .{ .num = sys.SYS_unmount, .handler = vfs_mount.sysUnmount },
    .{ .num = sys.SYS_nmount, .handler = vfs_mount.sysNmount },
    .{ .num = sys.SYS_statfs, .handler = vfs_mount.sysStatfs },
    .{ .num = sys.SYS_fstatfs, .handler = vfs_mount.sysFstatfs },
    .{ .num = sys.SYS_getfsstat, .handler = vfs_mount.sysGetfsstat },
    .{ .num = sys.SYS_sigpending, .handler = kern_signal.sysSigpending },
    .{ .num = sys.SYS_getcontext, .handler = kern_context.sysGetcontext },
    .{ .num = sys.SYS_setcontext, .handler = kern_context.sysSetcontext },
    .{ .num = sys.SYS_swapcontext, .handler = kern_context.sysSwapcontext },
    .{ .num = sys.SYS_execve, .handler = sysExecve },
    .{ .num = sys.SYS_fstat, .handler = vfs_syscalls.sysFstat },
    .{ .num = sys.SYS_mkdir, .handler = vfs_syscalls.sysMkdir },
    .{ .num = sys.SYS_rmdir, .handler = vfs_syscalls.sysRmdir },
    .{ .num = sys.SYS_stat, .handler = vfs_syscalls.sysFstatat },
    .{ .num = sys.SYS_getdents, .handler = vfs_syscalls.sysGetdents },
    .{ .num = sys.SYS_getcwd, .handler = vfs_getcwd.sysGetcwd },
    .{ .num = sys.SYS_klog, .handler = sys_generic.sysKlog },
    .{ .num = sys.SYS___sysctl, .handler = kern_sysctl.sysSysctl },
    .{ .num = sys.SYS___sysctlbyname, .handler = kern_sysctl.sysSysctlbyname },
    .{ .num = sys.SYS_getrlimit, .handler = kern_resource.sysGetrlimit },
    .{ .num = sys.SYS_setrlimit, .handler = kern_resource.sysSetrlimit },
    .{ .num = sys.SYS_fstatat, .handler = vfs_syscalls.sysFstatat },
    .{ .num = sys.SYS_clock_gettime, .handler = kern_time.sysClockGettime },
    .{ .num = sys.SYS_writev, .handler = sys_generic.sysWritev },
    .{ .num = sys.SYS_access, .handler = vfs_syscalls.sysAccess },
    .{ .num = sys.SYS_faccessat, .handler = vfs_syscalls.sysFaccessat },
    .{ .num = sys.SYS_eaccess, .handler = vfs_syscalls.sysEaccess },
    .{ .num = sys.SYS_flock, .handler = kern_lockf.sysFlock },
    .{ .num = sys.SYS_getdtablesize, .handler = sysGetdtablesize },
    .{ .num = sys.SYS_rtprio_thread, .handler = kern_thr.sysRtprioThread },
    .{ .num = sys.SYS__umtx_op, .handler = kern_umtx.sysUmtxOp },
    .{ .num = sys.SYS_thr_wake, .handler = kern_thr.sysThrWake },
    .{ .num = sys.SYS_thr_suspend, .handler = kern_thr.sysThrSuspend },
    .{ .num = sys.SYS_select, .handler = sys_poll.sysSelect },
    .{ .num = sys.SYS_pselect, .handler = sys_poll.sysPselect },
    .{ .num = sys.SYS_geteuid, .handler = kern_prot.sysGeteuid },
    .{ .num = sys.SYS_getegid, .handler = kern_prot.sysGetegid },
    .{ .num = sys.SYS_fcntl, .handler = sys_generic.sysFcntl },
    .{ .num = sys.SYS_openat, .handler = vfs_syscalls.sysOpenat },
    .{ .num = sys.SYS_readv, .handler = sys_generic.sysReadv },
    .{ .num = sys.SYS_pread, .handler = sys_generic.sysPread },
    .{ .num = sys.SYS_pwrite, .handler = sys_generic.sysPwrite },
    .{ .num = sys.SYS_setsid, .handler = kern_prot.sysSetsid },
    .{ .num = sys.SYS_getpgid, .handler = kern_prot.sysGetpgid },
    .{ .num = sys.SYS_getsid, .handler = kern_prot.sysGetsid },
    .{ .num = sys.SYS_setlogin, .handler = kern_prot.sysSetlogin },
    .{ .num = sys.SYS_getpgrp, .handler = kern_prot.sysGetpgrp },
    .{ .num = sys.SYS_setpgid, .handler = kern_prot.sysSetpgid },
    .{ .num = sys.SYS_fsync, .handler = vfs_syscalls.sysFsync },
    .{ .num = sys.SYS_fdatasync, .handler = vfs_syscalls.sysFsync },
    .{ .num = sys.SYS_ftruncate, .handler = vfs_syscalls.sysFtruncate },
    .{ .num = sys.SYS_truncate, .handler = vfs_syscalls.sysTruncate },
    .{ .num = sys.SYS_chmod, .handler = vfs_syscalls.sysChmod },
    .{ .num = sys.SYS_fchmod, .handler = vfs_syscalls.sysFchmod },
    .{ .num = sys.SYS_lchmod, .handler = vfs_syscalls.sysLchmod },
    .{ .num = sys.SYS_fchmodat, .handler = vfs_syscalls.sysFchmodat },
    .{ .num = sys.SYS_chown, .handler = vfs_syscalls.sysChown },
    .{ .num = sys.SYS_fchown, .handler = vfs_syscalls.sysFchown },
    .{ .num = sys.SYS_lchown, .handler = vfs_syscalls.sysLchown },
    .{ .num = sys.SYS_fchownat, .handler = vfs_syscalls.sysFchownat },
    .{ .num = sys.SYS_chflags, .handler = vfs_syscalls.sysChflags },
    .{ .num = sys.SYS_fchflags, .handler = vfs_syscalls.sysFchflags },
    .{ .num = sys.SYS_lchflags, .handler = vfs_syscalls.sysLchflags },
    .{ .num = sys.SYS_chflagsat, .handler = vfs_syscalls.sysChflagsat },
    .{ .num = sys.SYS_futimens, .handler = vfs_syscalls.sysFutimens },
    .{ .num = sys.SYS_utimensat, .handler = vfs_syscalls.sysUtimensat },
    .{ .num = sys.SYS_getppid, .handler = sysGetppid },
    .{ .num = sys.SYS_getgid, .handler = kern_prot.sysGetgid },
    .{ .num = sys.SYS_setgid, .handler = kern_prot.sysSetgid },
    .{ .num = sys.SYS_setegid, .handler = kern_prot.sysSetegid },
    .{ .num = sys.SYS_seteuid, .handler = kern_prot.sysSeteuid },
    .{ .num = sys.SYS_setreuid, .handler = kern_prot.sysSetreuid },
    .{ .num = sys.SYS_setregid, .handler = kern_prot.sysSetregid },
    .{ .num = sys.SYS_getresuid, .handler = kern_prot.sysGetresuid },
    .{ .num = sys.SYS_getresgid, .handler = kern_prot.sysGetresgid },
    .{ .num = sys.SYS_getgroups, .handler = kern_prot.sysGetgroups },
    .{ .num = sys.SYS_setgroups, .handler = kern_prot.sysSetgroups },
    .{ .num = sys.SYS_getlogin, .handler = kern_prot.sysGetlogin },
    .{ .num = sys.SYS_getitimer, .handler = kern_time.sysGetitimer },
    .{ .num = sys.SYS_setitimer, .handler = kern_time.sysSetitimer },
    .{ .num = sys.SYS_nanosleep, .handler = kern_time.sysNanosleep },
    .{ .num = sys.SYS_getpriority, .handler = kern_time.sysGetpriority },
    .{ .num = sys.SYS_setpriority, .handler = kern_time.sysSetpriority },
    .{ .num = sys.SYS_close_range, .handler = sysCloseRange },
    .{ .num = sys.SYS_minherit, .handler = vm_mmap.sysMinherit },
    .{ .num = sys.SYS_thr_self, .handler = kern_thr.sysThrSelf },
    .{ .num = sys.SYS_thr_kill, .handler = kern_thr.sysThrKill },
    .{ .num = sys.SYS_getrandom, .handler = sys_getrandom.sysGetrandom },
    .{ .num = sys.SYS_mkdirat, .handler = vfs_syscalls.sysMkdirat },
    .{ .num = sys.SYS_unlinkat, .handler = vfs_syscalls.sysUnlinkat },
    .{ .num = sys.SYS_fchdir, .handler = vfs_syscalls.sysFchdir },
    .{ .num = sys.SYS_pipe2, .handler = sys_pipe.sysPipe2 },
    .{ .num = sys.SYS_rename, .handler = vfs_syscalls.sysRename },
    .{ .num = sys.SYS_renameat, .handler = vfs_syscalls.sysRenameat },
    .{ .num = sys.SYS_getdirentries, .handler = vfs_syscalls.sysGetdirentries },
    .{ .num = sys.SYS_pathconf, .handler = vfs_syscalls.sysPathconf },
    .{ .num = sys.SYS_fpathconf, .handler = vfs_syscalls.sysFpathconf },
    .{ .num = sys.SYS_lpathconf, .handler = vfs_syscalls.sysLpathconf },
    .{ .num = sys.SYS_clock_getres, .handler = kern_time.sysClockGetres },
    .{ .num = sys.SYS_copy_file_range, .handler = vfs_syscalls.sysCopyFileRange },
    .{ .num = sys.SYS_umask, .handler = kern_resource.sysUmask },
    .{ .num = sys.SYS_getloginclass, .handler = kern_resource.sysGetloginclass },
    .{ .num = sys.SYS_setloginclass, .handler = kern_resource.sysSetloginclass },
    .{ .num = sys.SYS_poll, .handler = sys_poll.sysPoll },
    .{ .num = sys.SYS_readlink, .handler = vfs_syscalls.sysReadlink },
    .{ .num = sys.SYS_readlinkat, .handler = vfs_syscalls.sysReadlinkat },
    .{ .num = sys.SYS_cpuset_getaffinity, .handler = kern_cpuset.sysCpusetGetaffinity },
};

/// Number-to-handler table, indexed by system call number.
pub const table: [sys.MAXSYSCALL]?Handler = blk: {
    @setEvalBranchQuota(100000);
    var t: [sys.MAXSYSCALL]?Handler = undefined;
    for (&t) |*slot| {
        slot.* = null;
    }
    for (syscall_list) |entry| {
        t[entry.num] = entry.handler;
    }
    break :blk t;
};
