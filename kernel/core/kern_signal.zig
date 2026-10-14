// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Signal delivery.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_signal.c, reduced to
// posting a signal and delivering it when the process returns to user mode:
// the default action terminates where required, SIG_IGN drops the signal, and
// a caught signal builds a frame on the user stack, points the process at the
// handler and arranges for sigreturn(2) to restore the interrupted context.

const signal: type = @import("../sys/signal.zig");
const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const sys: type = @import("../sys/syscall.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_exit: type = @import("kern_exit.zig");
const kern_sched: type = @import("kern_sched.zig");
const errno: type = @import("../sys/errno.zig");
const ucontext: type = @import("../sys/ucontext.zig");

/// Signal bits.
fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig);
}

/// The job-control stop signals.
const STOPSIGMASK: u64 = (1 << signal.SIGSTOP) | (1 << signal.SIGTSTP) | (1 << signal.SIGTTIN) | (1 << signal.SIGTTOU);

/// True when `sig` stops `p` by default (SIGSTOP always does).
fn stops(p: *proc.Proc, sig: u32) bool {
    if ((bit(sig) & STOPSIGMASK) == 0) return false;
    return sig == signal.SIGSTOP or p.sig_handler[sig] == signal.SIG_DFL;
}

/// Post `sig` to `p`.
pub fn psignal(p: *proc.Proc, sig: u32) void {
    if (sig == 0 or sig >= signal.NSIG) {
        return;
    }
    if (p.state == .unused or p.state == .zombie) {
        return;
    }
    if (sig == signal.SIGCONT) {
        // Continuing cancels any pending stop and wakes a stopped process,
        // whatever its action for SIGCONT; the signal itself is only kept
        // when it is caught.
        p.sig_pending &= ~STOPSIGMASK;
        if (p.state == .stopped) {
            p.state = .runnable;
            p.stop_sig = 0;
            p.cont_report = true;
            notifyParent(p);
        }
        const act: u64 = p.sig_handler[sig];
        if (act == signal.SIG_DFL or act == signal.SIG_IGN) {
            return;
        }
    } else if ((bit(sig) & STOPSIGMASK) != 0) {
        p.sig_pending &= ~bit(signal.SIGCONT);
    }
    p.sig_pending |= bit(sig);
    // A process waiting in the kernel wakes up to notice it (its wait then
    // ends with EINTR, see interrupted()); SIGKILL also ends a stop.
    if (p.state == .sleeping or (p.state == .stopped and sig == signal.SIGKILL)) {
        p.state = .runnable;
    }
}

/// Post `sig` to every process in process group `pgid`. Returns how many
/// processes were signalled.
pub fn gsignal(pgid: i32, sig: u32) usize {
    var n: usize = 0;
    for (&kern_proc.table) |*q| {
        if (q.state != .unused and q.state != .zombie and q.pgid == pgid) {
            psignal(q, sig);
            n += 1;
        }
    }
    return n;
}

/// Tell the parent that `p` changed state (stopped, continued or exited):
/// SIGCHLD, and wake it if it waits in wait(2).
pub fn notifyParent(p: *proc.Proc) void {
    if (p.parent) |parent| {
        psignal(parent, signal.SIGCHLD);
        kern_sched.wakeup(@ptrCast(parent));
    }
}

/// Stop the current process with `sig` until SIGCONT (or SIGKILL) arrives.
fn stop(sig: u32) void {
    const p: *proc.Proc = kern_proc.current;
    p.stop_sig = sig;
    p.cont_report = false;
    p.state = .stopped;
    notifyParent(p);
    kern_sched.sched();
}

/// True when a pending, unblocked signal should end a wait in the kernel
/// with EINTR: one that is caught or kills by default (an ignored one, or
/// one whose default is to be discarded, does not interrupt). A pending
/// stop signal stops the process right here, inside the wait, as FreeBSD's
/// sleep queues do, and the wait carries on once it is continued.
pub fn interrupted(p: *proc.Proc) bool {
    var pend: u64 = p.sig_pending & ~p.sig_mask;
    while (pend != 0) {
        const sig: u32 = @intCast(@ctz(pend));
        pend &= pend - 1;
        if (stops(p, sig) and p == kern_proc.current) {
            p.sig_pending &= ~bit(sig);
            stop(sig);
            pend = p.sig_pending & ~p.sig_mask;
            continue;
        }
        const act: u64 = p.sig_handler[sig];
        if (act == signal.SIG_IGN) continue;
        if (act == signal.SIG_DFL and !signal.defaultTerminates(sig)) continue;
        return true;
    }
    return false;
}

/// The action `p` has for `sig`.
pub fn handler(p: *proc.Proc, sig: u32) u64 {
    return p.sig_handler[sig];
}

/// True when `sig` is ignored or blocked by `p` (job control then declines
/// to stop it, as with SIGTTIN for a background reader).
pub fn ignoredOrBlocked(p: *proc.Proc, sig: u32) bool {
    return p.sig_handler[sig] == signal.SIG_IGN or (p.sig_mask & bit(sig)) != 0;
}

/// Deliver pending, unblocked signals before returning to user mode. Called
/// from the trap dispatcher with the process's address space current.
pub fn deliver(frame: *arch.trapframe.TrapFrame) void {
    const p: *proc.Proc = kern_proc.current;
    while (true) {
        const pend: u64 = p.sig_pending & ~p.sig_mask;
        if (pend == 0) {
            break;
        }

        const sig: u32 = @intCast(@ctz(pend));
        p.sig_pending &= ~bit(sig);

        const act: u64 = p.sig_handler[sig];
        if (sig == signal.SIGKILL or (act == signal.SIG_DFL and signal.defaultTerminates(sig))) {
            kern_exit.exitSignal(sig);
        }
        if (stops(p, sig)) {
            stop(sig);
            continue;
        }
        if (act == signal.SIG_IGN or act == signal.SIG_DFL) {
            continue;
        }
        postsig(frame, p, sig, act);
        return;
    }
    // No handler ran: a mask sigsuspend(2) replaced comes back now.
    if (p.sig_oldmask) |old| {
        p.sig_mask = old;
        p.sig_oldmask = null;
    }
}

/// Run the handler `act` for `sig` (FreeBSD's postsig): block the signal
/// and the action's mask while it runs, and give the port's sendsig the mask
/// to restore afterwards.
fn postsig(frame: *arch.trapframe.TrapFrame, p: *proc.Proc, sig: u32, act: u64) void {
    const flags: u32 = p.sig_flags[sig];
    const oldmask: u64 = p.sig_oldmask orelse p.sig_mask;
    p.sig_oldmask = null;
    if (!arch.exec_machdep.sendsig(frame, sig, act, (flags & signal.SA_SIGINFO) != 0, oldmask)) {
        kern_exit.exitSignal(signal.SIGILL);
    }
    var block: u64 = p.sig_actmask[sig];
    if ((flags & signal.SA_NODEFER) == 0) block |= bit(sig);
    p.sig_mask = (oldmask | block) & ~signal.CANTMASK;
    if ((flags & signal.SA_RESETHAND) != 0) {
        p.sig_handler[sig] = signal.SIG_DFL;
        p.sig_flags[sig] = 0;
    }
}

/// struct sigaction, as passed to sigaction(2).
pub const Sigaction: type = extern struct {
    handler: u64,
    flags: i32,
    mask: [4]u32,
};

/// Whether the current process may signal `q` (FreeBSD's p_cansignal):
/// root may signal anyone, others their own processes, and SIGCONT may go
/// to any process of the same session.
fn cansignal(q: *proc.Proc, sig: u32) bool {
    const p: *proc.Proc = kern_proc.current;
    if (p.euid == 0) return true;
    if (sig == signal.SIGCONT and q.sid == p.sid) return true;
    return p.uid == q.uid or p.uid == q.svuid or p.euid == q.uid or p.euid == q.svuid;
}

/// kill(2): post signal `sig` to process `pid`; 0 names the caller's
/// process group, -1 every process but init and the caller, and any other
/// negative value the process group -pid. Signal 0 only checks that the
/// target exists and may be signalled.
pub fn sysKill(args: [sys.MAXARGS]u64) u64 {
    const pid: i32 = @bitCast(@as(u32, @truncate(args[0])));
    const sig: u32 = @intCast(args[1] & 0xffff);
    if (sig >= signal.NSIG) {
        return sys.signed(-errno.EINVAL);
    }
    const p: *proc.Proc = kern_proc.current;

    if (pid > 0) {
        const target: *proc.Proc = kern_proc.pfind(pid) orelse return sys.signed(-errno.ESRCH);
        if (!cansignal(target, sig)) return sys.signed(-errno.EPERM);
        if (sig != 0) psignal(target, sig);
        return 0;
    }

    const pgid: i32 = if (pid == 0) p.pgid else -pid;
    var found: bool = false;
    var denied: bool = false;
    for (&kern_proc.table) |*q| {
        if (q.state == .unused or q.state == .zombie) continue;
        if (pid == -1) {
            if (q.pid == 1 or q == p) continue;
        } else if (q.pgid != pgid) {
            continue;
        }
        if (!cansignal(q, sig)) {
            denied = true;
            continue;
        }
        found = true;
        if (sig != 0) psignal(q, sig);
    }
    if (found) return 0;
    return sys.signed(if (denied) -errno.EPERM else -errno.ESRCH);
}

/// sigaction(2): query and/or set the action for `sig`.
pub fn sysSigaction(args: [sys.MAXARGS]u64) u64 {
    const sig: u32 = @intCast(args[0] & 0xffff);
    const act_ptr: u64 = args[1];
    const oact_ptr: u64 = args[2];
    if (sig == 0 or sig >= signal.NSIG) {
        return sys.signed(-errno.EINVAL);
    }
    const p: *proc.Proc = kern_proc.current;

    var new: Sigaction = undefined;
    if (act_ptr != 0) {
        new = @as(*align(1) const Sigaction, @ptrFromInt(act_ptr)).*;
        // SIGKILL and SIGSTOP can be neither caught nor ignored.
        if ((sig == signal.SIGKILL or sig == signal.SIGSTOP) and new.handler != signal.SIG_DFL) {
            return sys.signed(-errno.EINVAL);
        }
    }
    if (oact_ptr != 0) {
        const oact: *align(1) Sigaction = @ptrFromInt(oact_ptr);
        oact.* = .{
            .handler = p.sig_handler[sig],
            .flags = @bitCast(p.sig_flags[sig]),
            .mask = ucontext.setOf(p.sig_actmask[sig]),
        };
    }
    if (act_ptr != 0) {
        p.sig_handler[sig] = new.handler;
        p.sig_flags[sig] = @bitCast(new.flags);
        p.sig_actmask[sig] = ucontext.maskOf(new.mask) & ~signal.CANTMASK;
        // Setting SIG_IGN (or SIG_DFL for a signal discarded by default)
        // drops it if pending.
        if (new.handler == signal.SIG_IGN or
            (new.handler == signal.SIG_DFL and !signal.defaultTerminates(sig) and !stops(p, sig)))
        {
            p.sig_pending &= ~bit(sig);
        }
    }
    return 0;
}

/// sigprocmask(2): `sigprocmask(how, set, oset)`, change the blocked-signal
/// mask by SIG_BLOCK, SIG_UNBLOCK or SIG_SETMASK.
pub fn sysSigprocmask(args: [sys.MAXARGS]u64) u64 {
    const how: u64 = args[0];
    const set_ptr: u64 = args[1];
    const oset_ptr: u64 = args[2];
    const p: *proc.Proc = kern_proc.current;

    const old: u64 = p.sig_mask;
    if (set_ptr != 0) {
        const set: u64 = ucontext.maskOf(@as(*align(1) const [4]u32, @ptrFromInt(set_ptr)).*);
        p.sig_mask = switch (how) {
            signal.SIG_BLOCK => old | set,
            signal.SIG_UNBLOCK => old & ~set,
            signal.SIG_SETMASK => set,
            else => return sys.signed(-errno.EINVAL),
        } & ~signal.CANTMASK;
    }
    if (oset_ptr != 0) {
        @as(*align(1) [4]u32, @ptrFromInt(oset_ptr)).* = ucontext.setOf(old);
    }
    return 0;
}

/// sigpending(2): the signals pending while blocked.
pub fn sysSigpending(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const p: *proc.Proc = kern_proc.current;
    @as(*align(1) [4]u32, @ptrFromInt(args[0])).* = ucontext.setOf(p.sig_pending & p.sig_mask);
    return 0;
}

/// sigsuspend(2): replace the signal mask with `sigmask` and wait for a
/// signal; the old mask returns once the handler has run (or at once, when
/// the signal needs no handler). Always ends with EINTR.
pub fn sysSigsuspend(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const p: *proc.Proc = kern_proc.current;
    const set: u64 = ucontext.maskOf(@as(*align(1) const [4]u32, @ptrFromInt(args[0])).*);
    p.sig_oldmask = p.sig_mask;
    p.sig_mask = set & ~signal.CANTMASK;
    while (!interrupted(p)) {
        kern_sched.sleep(@ptrCast(&p.sig_oldmask));
    }
    return sys.signed(-errno.EINTR);
}
