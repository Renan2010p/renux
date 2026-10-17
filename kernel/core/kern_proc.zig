// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The process and thread tables.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_proc.c and kern_thread.c,
// reduced to fixed tables: a process slot per program, a thread slot per
// thread, pid and thread id allocation, creation and release.
//
// `curthread` is the running thread and `current` its process (FreeBSD's
// curthread and curproc). The scheduler sets both whenever it switches.

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const signal: type = @import("../sys/signal.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const param: type = @import("../sys/param.zig");
const descrip: type = @import("kern_descrip.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const prf: type = @import("subr_prf.zig");
const kern_resource: type = @import("kern_resource.zig");
const vm_map: type = @import("../vm/vm_map.zig");
const kern_sched: type = @import("kern_sched.zig");

/// Maximum number of processes. FreeBSD's init restarts a getty as soon as it
/// exits, so a supervisor-style userland easily keeps several processes (a
/// session child per tty plus the getty itself); 64 leaves plenty of headroom
/// for those and for reaped-but-not-yet-collected zombies.
pub const NPROC: usize = 64;

/// Maximum number of threads in the system. A compiler keeps a worker thread
/// per CPU and a few more; 256 leaves room for several such programs.
pub const NTHREAD: usize = 256;

/// The first thread id (FreeBSD's PID_MAX + 1: thread ids never collide
/// with pids).
pub const TID_BASE: i32 = 100000;

pub var table: [NPROC]proc.Proc = undefined;
pub var threads: [NTHREAD]proc.Thread = @splat(.{});

/// The running process and thread.
pub var current: *proc.Proc = undefined;
pub var curthread: *proc.Thread = undefined;

var next_pid: i32 = 1;
var next_tid: i32 = TID_BASE + 1;

/// Reset the process-wide state of `p` to that of a new process.
fn resetProc(p: *proc.Proc) void {
    p.parent = null;
    p.exit_status = 0;
    p.stop_sig = 0;
    p.cont_report = false;
    p.pmap = 0;
    p.nthreads = 0;
    p.single_thread = null;
    descrip.fdinit(p);
    p.cwd = null;
    p.cwd_len = 0;
    p.brk = 0;
    p.mmap_next = 0;
    p.vm = .{};
    p.vm_borrowed_from = null;
    p.ppwait = false;
    p.uid = 0;
    p.euid = 0;
    p.svuid = 0;
    p.gid = 0;
    p.egid = 0;
    p.svgid = 0;
    p.ngroups = 1;
    p.groups[0] = 0;
    @memset(&p.login, 0);
    @memset(&p.loginclass, 0);
    p.cmask = 0o022;
    p.rlimits = kern_resource.defaults();
    p.name_len = 0;
    p.exe_path_len = 0;
    p.sig_pending = 0;
    p.itimer_due = 0;
    p.itimer_interval = 0;
    p.nice = 0;
    p.usage = .{};
    p.usage_children = .{};
    p.sig_handler = @splat(signal.SIG_DFL);
    p.sig_flags = @splat(0);
    p.sig_actmask = @splat(0);
}

/// Initialise the process and thread tables.
pub fn init() void {
    for (&table) |*p| {
        p.pid = 0;
        p.state = .unused;
        p.pgid = 0;
        p.sid = 0;
        resetProc(p);
    }
    prf.log(prf.LOG_INFO, "proc: %u process slots, %u thread slots", .{ NPROC, NTHREAD });
}

/// A new thread in process `p`, with its own kernel stack, not yet
/// runnable: the caller fills in its frame and context, then makes it
/// runnable (FreeBSD's thread_alloc). Null when the thread table is full or
/// memory runs out.
pub fn threadAlloc(p: *proc.Proc) ?*proc.Thread {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;
    for (&threads) |*td| {
        if (td.state != .unused) continue;
        const kpage: vm_page.PAddr = vm_page.physallocContig(param.KSTACK_PAGES) orelse return null;
        td.* = .{
            .tid = next_tid,
            .state = .sleeping, // not runnable until the caller says so
            .proc = p,
            .kstack_page = kpage.int(),
            .kstack_top = kpage.toKern(hhdm).int() + param.KSTACK_PAGES * param.PAGE_SIZE,
            .fpu = arch.fpu.initial(),
        };
        // The canary sits at the bottom of the stack (stacks grow down).
        kpage.toKern(hhdm).ptr(u64).* = param.KSTACK_CANARY;
        next_tid += 1;
        p.nthreads += 1;
        return td;
    }
    return null;
}

/// Free thread `td`'s kernel stack and slot. Never called for the running
/// thread: a thread that exits is marked dead and released by the scheduler
/// once it runs on another stack (FreeBSD's thread_reap).
pub fn threadRelease(td: *proc.Thread) void {
    if (td.kstack_page != 0) {
        vm_page.physfreeContig(vm_page.PAddr.fromInt(td.kstack_page), param.KSTACK_PAGES);
    }
    td.* = .{};
}

/// A new process with a fresh address space and its first thread. Returns
/// that thread (its process is `td.proc`); the caller sets up the thread's
/// frame and makes it runnable. Null when a table is full or memory runs
/// out.
pub fn alloc() ?*proc.Thread {
    for (&table) |*p| {
        if (p.state != .unused) continue;
        resetProc(p);
        p.pmap = arch.pmap.create() orelse return null;
        const td: *proc.Thread = threadAlloc(p) orelse {
            if (arch.boot.hhdmOffset()) |off| arch.pmap.destroy(p.pmap, off);
            p.pmap = 0;
            return null;
        };
        p.pid = next_pid;
        next_pid += 1;
        // A new process leads its own group and session until fork(2)
        // gives it the parent's.
        p.pgid = p.pid;
        p.sid = p.pid;
        p.state = .active;
        return td;
    }
    return null;
}

/// Release a process and every thread it still has (its last thread, when
/// it is reaped by wait(2)).
pub fn free(p: *proc.Proc) void {
    descrip.fd_closeAll(p);
    if (p.cwd) |cwd| {
        vfs_subr.vrele(cwd);
        p.cwd = null;
    }
    vm_map.deinit(&p.vm);
    if (p.pmap != 0) {
        if (arch.boot.hhdmOffset()) |off| {
            arch.pmap.destroy(p.pmap, off);
        }
    }
    for (&threads) |*td| {
        if (td.state != .unused and td.proc == p) threadRelease(td);
    }
    p.state = .unused;
    p.pid = 0;
    p.pmap = 0;
    p.nthreads = 0;
}

/// The address map process `p` runs in: its own, or its parent's while it
/// is a vfork child borrowing it.
pub fn vmOf(p: *proc.Proc) *vm_map.VmMap {
    return &(p.vm_borrowed_from orelse p).vm;
}

/// End a vfork child's borrowing of its parent's address space (it execs
/// into its own, or exits), and let the waiting parent go on (FreeBSD's
/// vfork wakeup in exec and exit1).
pub fn vforkDone(p: *proc.Proc) void {
    p.vm_borrowed_from = null;
    if (p.ppwait) {
        p.ppwait = false;
        kern_sched.wakeup(@ptrCast(&p.ppwait));
    }
}

/// Find a live process by pid, or null.
pub fn pfind(pid: i32) ?*proc.Proc {
    if (pid <= 0) return null;
    for (&table) |*p| {
        if (p.state != .unused and p.pid == pid) {
            return p;
        }
    }
    return null;
}

/// Find a live thread of process `p` by thread id, or null.
pub fn tfind(p: *proc.Proc, tid: i64) ?*proc.Thread {
    for (&threads) |*td| {
        if (td.state != .unused and td.state != .dead and td.proc == p and td.tid == tid) return td;
    }
    return null;
}

/// True when some live process belongs to process group `pgid`.
pub fn pgfind(pgid: i32) bool {
    for (&table) |*p| {
        if (p.state != .unused and p.state != .zombie and p.pgid == pgid) {
            return true;
        }
    }
    return false;
}
