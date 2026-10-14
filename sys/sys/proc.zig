// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Process and kernel thread state.
//
// This is a simplified counterpart of NetBSD's sys/sys/proc.h and sys/sys/lwp.h,
// fused into one structure for now: a process owns an address space (its page
// map) and a kernel thread with a kernel stack and a saved user frame.

const arch: type = @import("../arch/arch.zig");
const param: type = @import("param.zig");
const signal: type = @import("signal.zig");
const file: type = @import("file.zig");
const vnode: type = @import("vnode.zig");

pub const Context: type = arch.proc_md.Context;
pub const TrapFrame: type = arch.trapframe.TrapFrame;

/// Size of the per-process open file table.
pub const NFILE: usize = 16;

/// Process state.
pub const State: type = enum(u8) {
    unused = 0,
    runnable,
    running,
    sleeping,
    zombie,
};

/// Supplementary groups a process may hold (FreeBSD allows more; login
/// rarely sets more than a few).
pub const NGROUPS: usize = 16;

/// Address ranges marked with minherit(2) as zeroed in a fork child.
pub const NINHERIT: usize = 8;

pub const Range: type = struct {
    start: u64 = 0,
    end: u64 = 0,
};

/// Anonymous ranges filled on demand (one zeroed page at the first touch),
/// with the protection their pages get.
pub const NANON: usize = 64;

pub const AnonRange: type = struct {
    start: u64 = 0,
    end: u64 = 0,
    exec: bool = false,
    write: bool = true,
    /// Registration order: where ranges overlap, the newest mapping wins.
    seq: u64 = 0,
};

/// Resource limits a process holds (FreeBSD's RLIM_NLIMITS in 14.x).
pub const RLIM_NLIMITS: usize = 16;

/// A soft/hard limit pair (struct rlimit).
pub const Rlimit: type = extern struct {
    cur: i64,
    max: i64,
};

/// Size of a login class name, NUL included.
pub const MAXLOGCLASS: usize = 33;

/// Size of the login name, NUL included (FreeBSD's MAXLOGNAME).
pub const MAXLOGNAME: usize = 33;

pub const Proc: type = struct {
    pid: i32,
    state: State,
    parent: ?*Proc,
    exit_status: i32,
    /// Physical address of the top-level page table (CR3 value).
    pmap: u64,
    /// Kernel stack: physical page (for freeing) and top virtual address.
    kstack_page: u64,
    kstack_top: u64,
    /// Kernel thread context for swtch().
    context: Context,
    /// User frame used when the process first enters ring 3.
    frame: TrapFrame,
    /// Sleep channel (see kern_sched.sleep/wakeup).
    chan: ?*anyopaque,
    /// Open file table (descriptors 0..NFILE-1).
    fds: [NFILE]?*file.File,
    /// Close-on-exec flag per descriptor (FD_CLOEXEC).
    fd_cloexec: [NFILE]bool,
    /// Current working directory, or null before the root is mounted.
    cwd: ?*vnode.Vnode,
    /// Path of the current working directory (for getcwd).
    cwd_path: [param.MAXPATHLEN]u8,
    /// Length of cwd_path.
    cwd_len: usize,
    /// Current program break (end of the heap).
    brk: u64,
    /// Next address anonymous mmap() will hand out.
    mmap_next: u64,
    /// Ranges a fork child receives zero-filled (minherit INHERIT_ZERO), such
    /// as libc's arc4random state.
    inherit_zero: [NINHERIT]Range,
    /// Demand-zero anonymous memory (mmap MAP_ANON), see vm/vm_fault.zig.
    anon: [NANON]AnonRange,
    /// Value of the IA32_FS_BASE MSR: the user thread-pointer (TCB). Restored
    /// by the scheduler on every context switch.
    fsbase: u64,
    /// Credentials (FreeBSD's struct ucred): real, effective and saved user
    /// and group ids, the supplementary groups and the login name.
    uid: u32,
    euid: u32,
    svuid: u32,
    gid: u32,
    egid: u32,
    svgid: u32,
    ngroups: usize,
    groups: [NGROUPS]u32,
    login: [MAXLOGNAME]u8,
    /// Login class (setloginclass(2), from login.conf).
    loginclass: [MAXLOGCLASS]u8,
    /// File-creation mask (umask(2)).
    cmask: u16,
    /// Resource limits (getrlimit(2)/setrlimit(2)).
    rlimits: [RLIM_NLIMITS]Rlimit,
    /// Program name (basename of the executable), for ps/top/htop.
    name: [20]u8,
    /// Length of `name`.
    name_len: usize,
    /// ITIMER_REAL: tick at which SIGALRM is due (0: disarmed), and the
    /// reload interval in ticks (0: one-shot).
    itimer_due: u64,
    itimer_interval: u64,
    /// Scheduling priority set with setpriority(2) (-20..20); recorded, the
    /// round-robin scheduler does not weigh it yet.
    nice: i32,
    /// Pending signal bits.
    sig_pending: u64,
    /// Blocked signal bits.
    sig_mask: u64,
    /// Handler per signal (SIG_DFL/SIG_IGN or a user address).
    sig_handler: [signal.NSIG]u64,
};
