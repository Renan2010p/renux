// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Signals.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_sig.c. A signal is posted to
// a process (kill(2), the terminal, the clock) or to one thread (thr_kill(2)),
// and delivered when a thread returns to user mode: the default action
// terminates or stops the process where required, SIG_IGN drops the signal,
// and a caught signal builds a frame on the user stack, points the thread at
// the handler and arranges for sigreturn(2) to restore what it interrupted.
//
// As in FreeBSD (tdsendsignal), a signal sent to the process goes to one of
// its threads that does not block it, preferably one asleep in the kernel,
// which wakes up to take it; only when every thread blocks it does it wait
// on the process until a thread unblocks it. Each thread has its own mask.

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

/// The live threads of `p`, one at a time.
const ThreadIterator: type = struct {
    p: *proc.Proc,
    index: usize = 0,

    fn next(it: *ThreadIterator) ?*proc.Thread {
        while (it.index < kern_proc.threads.len) {
            const td: *proc.Thread = &kern_proc.threads[it.index];
            it.index += 1;
            if (td.state != .unused and td.state != .dead and td.proc == it.p) return td;
        }
        return null;
    }
};

fn threadsOf(p: *proc.Proc) ThreadIterator {
    return .{ .p = p };
}

/// Remove the signals in `mask` from `p` and all its threads.
fn clearPending(p: *proc.Proc, mask: u64) void {
    p.sig_pending &= ~mask;
    var it: ThreadIterator = threadsOf(p);
    while (it.next()) |td| td.sig_pending &= ~mask;
}

/// The signals waiting for thread `td`: its own and its process's.
fn pendingFor(td: *const proc.Thread) u64 {
    return td.sig_pending | td.proc.sig_pending;
}

/// The thread of `p` that should take `sig` (FreeBSD's sigtd): one that
/// does not block it, preferably one asleep in the kernel; null when they
/// all block it.
fn targetThread(p: *proc.Proc, sig: u32) ?*proc.Thread {
    var fallback: ?*proc.Thread = null;
    var it: ThreadIterator = threadsOf(p);
    while (it.next()) |td| {
        if ((td.sig_mask & bit(sig)) != 0) continue;
        if (td.state == .sleeping) return td;
        if (fallback == null) fallback = td;
    }
    return fallback;
}

/// Post `sig` to process `p`.
pub fn psignal(p: *proc.Proc, sig: u32) void {
    if (sig == 0 or sig >= signal.NSIG) return;
    if (p.state == .unused or p.state == .zombie) return;
    if (sig == signal.SIGCONT) {
        // Continuing cancels any pending stop and lets a stopped process
        // run again, whatever its action for SIGCONT; the signal itself is
        // only kept when it is caught.
        clearPending(p, STOPSIGMASK);
        if (p.state == .stopped) {
            p.state = .active;
            p.stop_sig = 0;
            p.cont_report = true;
            notifyParent(p);
        }
        const act: u64 = p.sig_handler[sig];
        if (act == signal.SIG_DFL or act == signal.SIG_IGN) return;
    } else if ((bit(sig) & STOPSIGMASK) != 0) {
        clearPending(p, bit(signal.SIGCONT));
    }
    // SIGKILL ends a stop at once: the process must run to die.
    if (sig == signal.SIGKILL and p.state == .stopped) p.state = .active;

    if (targetThread(p, sig)) |td| {
        td.sig_pending |= bit(sig);
        // A thread waiting in the kernel wakes up to notice it (its wait
        // then ends with EINTR, see interrupted()).
        kern_sched.wakeThread(td);
    } else {
        p.sig_pending |= bit(sig);
    }
}

/// Post `sig` to thread `td` alone (thr_kill(2)). The signals that act on
/// the whole process (stopping, continuing, killing) go to the process.
pub fn tdsignal(td: *proc.Thread, sig: u32) void {
    if (sig == 0 or sig >= signal.NSIG) return;
    if (sig == signal.SIGKILL or sig == signal.SIGCONT or (bit(sig) & STOPSIGMASK) != 0) {
        psignal(td.proc, sig);
        return;
    }
    td.sig_pending |= bit(sig);
    if ((td.sig_mask & bit(sig)) == 0) kern_sched.wakeThread(td);
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

/// Stop the current process with `sig` until SIGCONT (or SIGKILL) arrives:
/// none of its threads runs meanwhile.
fn stop(sig: u32) void {
    const p: *proc.Proc = kern_proc.current;
    p.stop_sig = sig;
    p.cont_report = false;
    p.state = .stopped;
    notifyParent(p);
    kern_sched.yield();
}

/// True when the running thread should end a wait in the kernel with EINTR:
/// another thread is making it exit (exit(2) or execve(2) in a sibling), or
/// a pending signal it does not block is caught or kills by default (an
/// ignored one, or one whose default is to be discarded, does not
/// interrupt). A pending stop signal stops the process right here, inside
/// the wait, as FreeBSD's sleep queues do, and the wait carries on once it
/// is continued.
pub fn interrupted() bool {
    const td: *proc.Thread = kern_proc.curthread;
    const p: *proc.Proc = td.proc;
    if (p.single_thread) |survivor| {
        if (survivor != td) return true;
    }
    var pend: u64 = pendingFor(td) & ~td.sig_mask;
    while (pend != 0) {
        const sig: u32 = @intCast(@ctz(pend));
        pend &= pend - 1;
        if (stops(p, sig)) {
            clearPending(p, bit(sig));
            stop(sig);
            pend = pendingFor(td) & ~td.sig_mask;
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

/// True when `sig` is ignored by `p` or blocked by all its threads (job
/// control then declines to stop it, as with SIGTTIN for a background
/// reader).
pub fn ignoredOrBlocked(p: *proc.Proc, sig: u32) bool {
    if (p.sig_handler[sig] == signal.SIG_IGN) return true;
    return targetThread(p, sig) == null;
}

/// Take the lowest pending signal thread `td` does not block, from its own
/// set first, then from its process's; 0 when there is none.
fn takeSignal(td: *proc.Thread) u32 {
    const own: u64 = td.sig_pending & ~td.sig_mask;
    if (own != 0) {
        const sig: u32 = @intCast(@ctz(own));
        td.sig_pending &= ~bit(sig);
        return sig;
    }
    const shared: u64 = td.proc.sig_pending & ~td.sig_mask;
    if (shared != 0) {
        const sig: u32 = @intCast(@ctz(shared));
        td.proc.sig_pending &= ~bit(sig);
        return sig;
    }
    return 0;
}

/// Deliver pending, unblocked signals before the running thread returns to
/// user mode. Called from the trap dispatcher with the process's address
/// space current.
pub fn deliver(frame: *arch.trapframe.TrapFrame) void {
    const td: *proc.Thread = kern_proc.curthread;
    const p: *proc.Proc = td.proc;
    while (true) {
        const sig: u32 = takeSignal(td);
        if (sig == 0) break;

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
        postsig(frame, td, sig, act);
        return;
    }
    // No handler ran: a mask sigsuspend(2) replaced comes back now.
    if (td.sig_oldmask) |old| {
        td.sig_mask = old;
        td.sig_oldmask = null;
    }
}

/// Run the handler `act` for `sig` in thread `td` (FreeBSD's postsig): block
/// the signal and the action's mask while it runs, and give the port's
/// sendsig the mask to restore afterwards.
fn postsig(frame: *arch.trapframe.TrapFrame, td: *proc.Thread, sig: u32, act: u64) void {
    const p: *proc.Proc = td.proc;
    const flags: u32 = p.sig_flags[sig];
    const oldmask: u64 = td.sig_oldmask orelse td.sig_mask;
    td.sig_oldmask = null;
    const onstack: bool = (flags & signal.SA_ONSTACK) != 0;
    if (!arch.exec_machdep.sendsig(frame, td, sig, act, (flags & signal.SA_SIGINFO) != 0, onstack, oldmask)) {
        kern_exit.exitSignal(signal.SIGILL);
    }
    var block: u64 = p.sig_actmask[sig];
    if ((flags & signal.SA_NODEFER) == 0) block |= bit(sig);
    td.sig_mask = (oldmask | block) & ~signal.CANTMASK;
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
            clearPending(p, bit(sig));
        }
    }
    return 0;
}

/// sigprocmask(2): `sigprocmask(how, set, oset)`, change the calling
/// thread's blocked-signal mask by SIG_BLOCK, SIG_UNBLOCK or SIG_SETMASK.
pub fn sysSigprocmask(args: [sys.MAXARGS]u64) u64 {
    const how: u64 = args[0];
    const set_ptr: u64 = args[1];
    const oset_ptr: u64 = args[2];
    const td: *proc.Thread = kern_proc.curthread;

    const old: u64 = td.sig_mask;
    if (set_ptr != 0) {
        const set: u64 = ucontext.maskOf(@as(*align(1) const [4]u32, @ptrFromInt(set_ptr)).*);
        td.sig_mask = switch (how) {
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

/// True when `sp` lies on thread `td`'s alternate signal stack (FreeBSD's
/// sigonstack).
pub fn sigonstack(td: *const proc.Thread, sp: u64) bool {
    const ss: ucontext.Stack = td.altstack orelse return false;
    return sp -% ss.ss_sp < ss.ss_size;
}

/// sigaltstack(2): `sigaltstack(ss, oss)`, set or query the calling
/// thread's alternate signal stack (FreeBSD's kern_sigaltstack). The stack
/// cannot change while a handler runs on it.
pub fn sysSigaltstack(args: [sys.MAXARGS]u64) u64 {
    const td: *proc.Thread = kern_proc.curthread;
    const sp: u64 = if (arch.trap.currentFrame()) |f| f.rsp else 0;
    const oonstack: bool = sigonstack(td, sp);

    var old: ucontext.Stack = td.altstack orelse .{ .ss_sp = 0, .ss_size = 0, .ss_flags = 0 };
    old.ss_flags = if (td.altstack != null) (if (oonstack) signal.SS_ONSTACK else 0) else signal.SS_DISABLE;

    if (args[0] != 0) {
        if (oonstack) return sys.signed(-errno.EPERM);
        const ss: ucontext.Stack = @as(*align(1) const ucontext.Stack, @ptrFromInt(args[0])).*;
        if ((ss.ss_flags & ~signal.SS_DISABLE) != 0) return sys.signed(-errno.EINVAL);
        if ((ss.ss_flags & signal.SS_DISABLE) == 0) {
            if (ss.ss_size < signal.MINSIGSTKSZ) return sys.signed(-errno.ENOMEM);
            td.altstack = .{ .ss_sp = ss.ss_sp, .ss_size = ss.ss_size, .ss_flags = 0 };
        } else {
            td.altstack = null;
        }
    }
    if (args[1] != 0) @as(*align(1) ucontext.Stack, @ptrFromInt(args[1])).* = old;
    return 0;
}

/// sigpending(2): the signals pending for the calling thread while it
/// blocks them.
pub fn sysSigpending(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const td: *proc.Thread = kern_proc.curthread;
    @as(*align(1) [4]u32, @ptrFromInt(args[0])).* = ucontext.setOf(pendingFor(td) & td.sig_mask);
    return 0;
}

/// sigsuspend(2): replace the signal mask with `sigmask` and wait for a
/// signal; the old mask returns once the handler has run (or at once, when
/// the signal needs no handler). Always ends with EINTR.
pub fn sysSigsuspend(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const td: *proc.Thread = kern_proc.curthread;
    const set: u64 = ucontext.maskOf(@as(*align(1) const [4]u32, @ptrFromInt(args[0])).*);
    td.sig_oldmask = td.sig_mask;
    td.sig_mask = set & ~signal.CANTMASK;
    while (!interrupted()) {
        kern_sched.sleep(@ptrCast(&td.sig_oldmask));
    }
    return sys.signed(-errno.EINTR);
}
