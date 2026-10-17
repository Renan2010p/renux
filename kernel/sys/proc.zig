// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Processes and threads.
//
// The Zig counterpart of FreeBSD's sys/sys/proc.h, which splits the two:
//
//   struct proc    (Proc)    what the threads of a program share: the address
//                            space, the open files, the working directory,
//                            the credentials, the limits, the signal actions,
//                            the process group and the place in the process
//                            tree;
//   struct thread  (Thread)  what each thread has of its own: a kernel stack
//                            and the saved registers (kernel context, user
//                            frame, FPU, TLS base), its run state, its signal
//                            mask and the signals sent to it alone.
//
// The scheduler runs threads; kern_proc.curthread is the running one and
// kern_proc.current its process (FreeBSD's curthread and curproc).

const arch: type = @import("../arch/arch.zig");
const param: type = @import("param.zig");
const signal: type = @import("signal.zig");
const file: type = @import("file.zig");
const filedesc: type = @import("filedesc.zig");
const vnode: type = @import("vnode.zig");
const vm_map: type = @import("../vm/vm_map.zig");
const ucontext: type = @import("ucontext.zig");

pub const Context: type = arch.proc_md.Context;
pub const TrapFrame: type = arch.trapframe.TrapFrame;

/// Process state: its place in its life, not whether it runs (that is each
/// thread's ThreadState).
pub const State: type = enum(u8) {
    unused = 0,
    /// Alive: its threads run, wait or sleep.
    active,
    /// Stopped by a job-control signal until SIGCONT: none of its threads
    /// runs.
    stopped,
    /// Exited, waiting for its parent's wait(2).
    zombie,
};

/// Thread state (FreeBSD's TDS_*).
pub const ThreadState: type = enum(u8) {
    unused = 0,
    /// Waiting for the CPU.
    runnable,
    /// On the CPU.
    running,
    /// Waiting in the kernel on a channel (see kern_sched.sleep).
    sleeping,
    /// Exited; the scheduler frees its kernel stack once it has left it.
    dead,
};

/// A thread (FreeBSD's struct thread).
pub const Thread: type = struct {
    /// Thread id: FreeBSD numbers threads from 100000 up, apart from pids.
    tid: i32 = 0,
    state: ThreadState = .unused,
    /// The process the thread belongs to.
    proc: *Proc = undefined,
    /// Kernel stack: physical page (for freeing) and top virtual address.
    kstack_page: u64 = 0,
    kstack_top: u64 = 0,
    /// Kernel context for swtch().
    context: Context = undefined,
    /// User frame the thread first enters ring 3 with.
    frame: TrapFrame = undefined,
    /// The frame of the trap (system call, fault, interrupt) the thread
    /// entered the kernel from user mode with, for the calls that need the
    /// user registers (fork, sigreturn, getcontext, ...).
    trapframe: ?*TrapFrame = null,
    /// Sleep channel (see kern_sched.sleep/wakeup), and the tick at which a
    /// timed sleep ends (0: none).
    chan: ?*anyopaque = null,
    wake_tick: u64 = 0,
    /// Value of the IA32_FS_BASE MSR: the user thread pointer (TLS),
    /// restored by the scheduler when the thread runs.
    fsbase: u64 = 0,
    /// Blocked signals (FreeBSD's td_sigmask).
    sig_mask: u64 = 0,
    /// Signals sent to this thread alone, or given to it from the process
    /// (FreeBSD's td_siglist).
    sig_pending: u64 = 0,
    /// The mask sigsuspend(2) replaced, restored once the signal that ended
    /// it is handled (FreeBSD's td_oldsigmask).
    sig_oldmask: ?u64 = null,
    /// The alternate signal stack set with sigaltstack(2), or null when
    /// none is enabled (FreeBSD's td_sigstk and TDP_ALTSTACK).
    altstack: ?ucontext.Stack = null,
    /// thr_wake(2) arrived; thr_suspend(2) consumes it.
    thr_woken: bool = false,
    /// Name set with thr_set_name(2).
    name: [20]u8 = @splat(0),
    /// The thread's x87/SSE registers while it is not running.
    fpu: arch.fpu.Savefpu = undefined,
};

/// What a process has used, the part of FreeBSD's struct rusage that Renux
/// accounts: clock ticks spent in user mode and in the kernel (statclock),
/// and the largest resident set seen, in KiB (ru_maxrss).
pub const Usage: type = struct {
    uticks: u64 = 0,
    sticks: u64 = 0,
    maxrss_kb: u64 = 0,

    /// Add `other` to this usage (FreeBSD's ruadd: times add up, the
    /// resident set takes the larger).
    pub fn add(self: *Usage, other: Usage) void {
        self.uticks += other.uticks;
        self.sticks += other.sticks;
        self.maxrss_kb = @max(self.maxrss_kb, other.maxrss_kb);
    }
};

/// Supplementary groups a process may hold (FreeBSD allows more; login
/// rarely sets more than a few).
pub const NGROUPS: usize = 16;

/// Resource limits a process holds (FreeBSD's RLIM_NLIMITS in 14.x).
pub const RLIM_NLIMITS: usize = 16;

/// A soft/hard limit pair (struct rlimit).
pub const Rlimit: type = extern struct {
    cur: i64,
    max: i64,
};

comptime {
    // struct rlimit crosses the FreeBSD ABI: its layout is fixed, and a
    // mistake here would show up as garbage in getrlimit(2)/setrlimit(2).
    const checks: type = @import("checks.zig");
    checks.assertSize(Rlimit, 16);
    checks.assertOffsetOf(Rlimit, "cur", 0);
    checks.assertOffsetOf(Rlimit, "max", 8);
    checks.assertNoPadding(Rlimit);
}

/// Size of a login class name, NUL included.
pub const MAXLOGCLASS: usize = 33;

/// Size of the login name, NUL included (FreeBSD's MAXLOGNAME).
pub const MAXLOGNAME: usize = 33;

pub const Proc: type = struct {
    pid: i32,
    state: State,
    parent: ?*Proc,
    /// Status wait(2) reports once the process is a zombie: the exit code in
    /// bits 8..15, or the terminating signal in the low 7 bits.
    exit_status: i32,
    /// Process group and session (FreeBSD's p_pgrp and its pg_session),
    /// named by their leaders' pids.
    pgid: i32,
    sid: i32,
    /// The signal that stopped the process, waiting to be reported to the
    /// parent by wait(2) with WUNTRACED (0: nothing to report).
    stop_sig: u32,
    /// Continued by SIGCONT, waiting to be reported with WCONTINUED.
    cont_report: bool,
    /// Physical address of the top-level page table (CR3 value).
    pmap: u64,
    /// Threads of the process that have not exited.
    nthreads: u32,
    /// The thread that is making the others exit (for exit(2) or execve(2);
    /// FreeBSD's p_singlethread), or null.
    single_thread: ?*Thread,
    /// The file descriptor table (FreeBSD's p_fd); see sys/filedesc.zig.
    fd: filedesc.FileDesc,
    /// Current working directory, or null before the root is mounted.
    cwd: ?*vnode.Vnode,
    /// Path of the current working directory (for getcwd).
    cwd_path: [param.MAXPATHLEN]u8,
    /// Length of cwd_path.
    cwd_len: usize,
    /// Current program break (end of the heap).
    brk: u64,
    /// Where mmap(2) starts looking for room when the caller names no
    /// address.
    mmap_next: u64,
    /// The address map: what the user address space holds (vm/vm_map.zig).
    vm: vm_map.VmMap,
    /// A vfork child (rfork RFMEM) runs in its parent's address space until
    /// it execs or exits: this is the parent whose map and page tables it
    /// borrows (FreeBSD shares the vmspace), or null.
    vm_borrowed_from: ?*Proc,
    /// The parent waits until this vfork child execs or exits (FreeBSD's
    /// P_PPWAIT).
    ppwait: bool,
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
    /// Absolute path of the executable, as execve(2) resolved it
    /// (sysctl kern.proc.pathname, which std.process.executablePath and the
    /// Zig compiler use to find their installation).
    exe_path: [param.MAXPATHLEN]u8,
    /// Length of `exe_path`.
    exe_path_len: usize,
    /// Program name (basename of the executable), for ps/top/htop.
    name: [20]u8,
    /// Length of `name`.
    name_len: usize,
    /// ITIMER_REAL: tick at which SIGALRM is due (0: disarmed), and the
    /// reload interval in ticks (0: one-shot).
    itimer_due: u64,
    itimer_interval: u64,
    /// Resources this process used, and those of its reaped children
    /// (FreeBSD's p_ru and p_stats->p_cru).
    usage: Usage,
    usage_children: Usage,
    /// Scheduling priority set with setpriority(2) (-20..20); recorded, the
    /// round-robin scheduler does not weigh it yet.
    nice: i32,
    /// Signals sent to the process that no thread could take yet, because
    /// all of them block them (FreeBSD's p_siglist).
    sig_pending: u64,
    /// Handler per signal (SIG_DFL/SIG_IGN or a user address).
    sig_handler: [signal.NSIG]u64,
    /// sa_flags and sa_mask of each signal's action.
    sig_flags: [signal.NSIG]u32,
    sig_actmask: [signal.NSIG]u64,
};
