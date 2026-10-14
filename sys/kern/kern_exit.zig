// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// exit() and wait().
//
// The Zig counterpart of NetBSD's sys/kern/kern_exit.c (simplified): a process
// that exits becomes a zombie until its parent reaps it with wait(); a parent
// with no zombie child sleeps on itself and is woken when a child exits.

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const prf: type = @import("subr_prf.zig");
const cons: type = @import("../dev/cons.zig");
const tty: type = @import("tty.zig");
const kern_signal: type = @import("kern_signal.zig");
const errno: type = @import("../sys/errno.zig");

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
    const p = kern_proc.current;
    p.exit_status = xstat;
    p.state = .zombie;
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

    // Switch away; being a zombie, this process is never scheduled again.
    kern_sched.sched();
    arch.cpu.idle();
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
/// yet, or a negative errno (ECHILD: no such child; EINTR: a signal).
pub fn wait(sel: i32, status_out: *i32, options: u32) i32 {
    const parent = kern_proc.current;

    while (true) {
        var has_child: bool = false;
        for (&kern_proc.table) |*c| {
            if (!selected(c, parent, sel)) continue;
            has_child = true;
            if (c.state == .zombie) {
                const pid: i32 = c.pid;
                status_out.* = c.exit_status;
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
        if (kern_signal.interrupted(parent)) {
            return -errno.EINTR;
        }

        kern_sched.sleep(@ptrCast(parent));
    }
}
