// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// exit(), wait() and the end of threads.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_exit.c and the exit side of
// kern_thread.c. A process that exits first makes its other threads exit
// (singleThread), then becomes a zombie until its parent reaps it with
// wait(); a parent with no zombie child sleeps on itself and is woken when a
// child exits. A thread that exits alone (thr_exit(2)) is marked dead, and
// the scheduler frees its kernel stack once it has switched away from it.

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const vm_map: type = @import("../vm/vm_map.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kern_sched: type = @import("kern_sched.zig");
const prf: type = @import("subr_prf.zig");
const cons: type = @import("../dev/cons.zig");
const tty: type = @import("tty.zig");
const kern_signal: type = @import("kern_signal.zig");
const errno: type = @import("../sys/errno.zig");
const kern_resource: type = @import("kern_resource.zig");

/// Terminate the current process with exit code `status`. Never returns.
pub fn exit(status: i32) noreturn {
    // FreeBSD wait(2) status: exit code in bits 8..15, low 7 bits zero for a
    // normal exit.
    finish((status & 0xff) << 8);
}

/// Terminate the current process because of signal `sig`, so wait(2)
/// reports WIFSIGNALED with WTERMSIG == sig. Never returns.
pub fn exitSignal(sig: u32) noreturn {
    finish(@intCast(sig & 0x7f));
}

fn finish(xstat: i32) noreturn {
    singleThread();
    const td: *proc.Thread = kern_proc.curthread;
    const p: *proc.Proc = td.proc;
    p.exit_status = xstat;
    p.state = .zombie;

    // Close the descriptors now, as FreeBSD's exit1 does (fdescfree): a
    // parent reading this process's output through a pipe sees end-of-file
    // at once, instead of only after it has reaped the child -- which it
    // would never do while it waits for that end-of-file.
    kern_descrip.fd_closeAll(p);
    if (p.cwd) |cwd| {
        vfs_subr.vrele(cwd);
        p.cwd = null;
    }
    // Free the memory too (vmspace_exit): every user page and mapped file.
    // The page tables themselves stay until the process is reaped, since
    // this thread still runs on them. A vfork child owns none of the
    // address space it runs in: it gives it back to the waiting parent.
    if (p.vm_borrowed_from != null) {
        p.pmap = 0;
    } else {
        kern_resource.sampleRss(p);
        vm_map.remove(&p.vm, p.pmap, 0, arch.vmparam.VM_MAXUSER_ADDRESS) catch {};
    }
    vm_map.deinit(&p.vm);
    kern_proc.vforkDone(p);
    prf.log(prf.LOG_DEBUG, "exit: pid %d status %x", .{ p.pid, xstat });

    // A graphical program that dies in KD_GRAPHICS gives the screen back.
    cons.cnProcExit(p.pid);

    // A session leader that exits takes its controlling terminal with it:
    // the foreground group is hung up (FreeBSD's killjobc).
    if (p.sid == p.pid) {
        tty.sessionExit(p.sid);
    }

    // Orphans are adopted by init, which reaps them.
    const initproc: ?*proc.Proc = kern_proc.pfind(1);
    for (&kern_proc.table) |*c| {
        if (c.state != .unused and c.parent == p) {
            c.parent = initproc;
            if (c.state == .zombie) {
                if (initproc) |ip| kern_sched.wakeup(@ptrCast(ip));
            }
        }
    }

    // Tell the parent (SIGCHLD) and wake it if it is blocked in wait().
    kern_signal.notifyParent(p);

    // The last thread goes too: marked dead only now, right before switching
    // away for good (the steps above may sleep), so the scheduler frees its
    // kernel stack once it no longer runs on it.
    td.state = .dead;
    p.nthreads = 0;
    kern_sched.sched();
    arch.cpu.idle();
}

/// End the running thread, which is not the last of its process (thr_exit(2),
/// or a thread leaving because a sibling single-threads the process). Never
/// returns.
pub fn threadExit() noreturn {
    const td: *proc.Thread = kern_proc.curthread;
    const p: *proc.Proc = td.proc;
    td.state = .dead;
    p.nthreads -= 1;
    // A sibling waiting in singleThread() counts the threads left.
    kern_sched.wakeup(@ptrCast(&p.nthreads));
    kern_sched.sched();
    unreachable; // a dead thread is never scheduled again
}

/// Make every other thread of the current process exit and wait until they
/// have, before exit(2) or execve(2) (FreeBSD's thread_single(SINGLE_EXIT)).
/// The others notice when they next return to user mode, or at once if they
/// wait in the kernel (their wait ends with EINTR, see
/// kern_signal.interrupted). When another thread is already doing this, the
/// running one exits instead.
pub fn singleThread() void {
    const td: *proc.Thread = kern_proc.curthread;
    const p: *proc.Proc = td.proc;
    if (p.single_thread) |other| {
        if (other != td) threadExit();
    }
    if (p.nthreads <= 1) return;
    p.single_thread = td;
    for (&kern_proc.threads) |*sibling| {
        if (sibling != td and sibling.proc == p) kern_sched.wakeThread(sibling);
    }
    while (p.nthreads > 1) kern_sched.sleep(@ptrCast(&p.nthreads));
    p.single_thread = null;
}

/// Called on the way back to user mode: a thread whose sibling is
/// single-threading the process exits here.
pub fn checkSingleThread() void {
    const td: *proc.Thread = kern_proc.curthread;
    if (td.proc.single_thread) |survivor| {
        if (survivor != td) threadExit();
    }
}

/// wait4(2) options.
pub const WNOHANG: u32 = 1;
pub const WUNTRACED: u32 = 2;
pub const WCONTINUED: u32 = 4;

/// Whether child `c` is one `sel` names: a pid, -1 for any child, 0 for the
/// caller's process group, or -pgid.
fn selected(c: *proc.Proc, parent: *proc.Proc, sel: i32) bool {
    if (c.state == .unused or c.parent != parent) return false;
    if (sel == -1) return true;
    if (sel > 0) return c.pid == sel;
    if (sel == 0) return c.pgid == parent.pgid;
    return c.pgid == -sel;
}

/// Wait for a child selected by `sel` to exit (or, with WUNTRACED, stop;
/// with WCONTINUED, continue) and report it. Returns the child's pid with
/// its wait status in `status_out`, 0 under WNOHANG when nothing changed
/// yet, or a negative errno (ECHILD: no such child; EINTR: a signal). The
/// usage of a reaped child goes to `usage_out`, and with its own children's
/// to the caller's children total (FreeBSD's proc_reap).
pub fn wait(sel: i32, status_out: *i32, options: u32, usage_out: ?*proc.Usage) i32 {
    const parent = kern_proc.current;

    while (true) {
        var has_child: bool = false;
        for (&kern_proc.table) |*c| {
            if (!selected(c, parent, sel)) continue;
            has_child = true;
            if (c.state == .zombie) {
                const pid: i32 = c.pid;
                status_out.* = c.exit_status;
                if (usage_out) |u| u.* = c.usage;
                parent.usage_children.add(c.usage);
                parent.usage_children.add(c.usage_children);
                kern_proc.free(c);
                return pid;
            }
            if ((options & WUNTRACED) != 0 and c.state == .stopped and c.stop_sig != 0) {
                status_out.* = @intCast((c.stop_sig << 8) | 0x7f);
                c.stop_sig = 0;
                return c.pid;
            }
            if ((options & WCONTINUED) != 0 and c.cont_report) {
                status_out.* = 0xffff; // _WCONTINUED
                c.cont_report = false;
                return c.pid;
            }
        }

        if (!has_child) {
            return -errno.ECHILD;
        }
        if ((options & WNOHANG) != 0) {
            status_out.* = 0;
            return 0;
        }
        if (kern_signal.interrupted()) {
            return -errno.EINTR;
        }

        kern_sched.sleep(@ptrCast(parent));
    }
}
