// SPDX-License-Identifier: GPL-2.0-only
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
const kern_exec: type = @import("kern_exec.zig");

/// Post `sig` to `p`.
pub fn psignal(p: *proc.Proc, sig: u32) void {
    if (sig == 0 or sig >= signal.NSIG) {
        return;
    }
    p.sig_pending |= @as(u64, 1) << @intCast(sig);
}

/// The action `p` has for `sig`.
pub fn handler(p: *proc.Proc, sig: u32) u64 {
    return p.sig_handler[sig];
}

/// Deliver a pending, unblocked signal before returning to user mode. Called
/// from the trap dispatcher with the process's address space current.
pub fn deliver(frame: *arch.trapframe.TrapFrame) void {
    const p: *proc.Proc = kern_proc.current;
    const pend: u64 = p.sig_pending & ~p.sig_mask;
    if (pend == 0) {
        return;
    }

    const sig: u32 = @intCast(@ctz(pend));
    p.sig_pending &= ~(@as(u64, 1) << @intCast(sig));

    const act: u64 = p.sig_handler[sig];
    if (act == signal.SIG_IGN) {
        return;
    }
    if (act == signal.SIG_DFL) {
        if (signal.defaultTerminates(sig)) {
            kern_exit.exit(@intCast(128 + sig));
        }
        return;
    }
    buildFrame(frame, sig, act);
}

/// Push a signal frame onto the user stack and divert the process to `handler`.
/// The handler's return address is the sigreturn trampoline.
fn buildFrame(frame: *arch.trapframe.TrapFrame, sig: u32, act: u64) void {
    const T: type = arch.trapframe.TrapFrame;

    // Save the interrupted context just below the current stack pointer.
    var base: u64 = (frame.rsp - @sizeOf(T)) & ~@as(u64, 15);
    const saved: *T = @ptrFromInt(base);
    saved.* = frame.*;

    // The handler returns into the trampoline, which then reads the saved
    // frame from the stack.
    base -= 8;
    const ret: *u64 = @ptrFromInt(base);
    ret.* = kern_exec.trampolineVa();

    frame.rsp = base;
    frame.rip = act;
    frame.rdi = sig;
}

/// An installed signal action, as passed to sigaction(2).
pub const Sigaction: type = extern struct {
    handler: u64,
    mask: u64,
};

/// Find a process by pid, or null.
fn findProc(pid: i32) ?*proc.Proc {
    for (&kern_proc.table) |*p| {
        if (p.state != .unused and p.pid == pid) {
            return p;
        }
    }
    return null;
}

/// kill(2): post signal `sig` to process `pid`.
pub fn sysKill(args: [sys.MAXARGS]u64) u64 {
    const pid: i32 = @bitCast(@as(u32, @truncate(args[0])));
    const sig: u32 = @intCast(args[1] & 0xffff);
    if (sig == 0 or sig >= signal.NSIG) {
        return sys.ERROR;
    }
    const target: *proc.Proc = findProc(pid) orelse return sys.ERROR;
    psignal(target, sig);
    return 0;
}

/// sigaction(2): query and/or set the action for `sig`.
pub fn sysSigaction(args: [sys.MAXARGS]u64) u64 {
    const sig: u32 = @intCast(args[0] & 0xffff);
    const act_ptr: u64 = args[1];
    const oact_ptr: u64 = args[2];
    if (sig == 0 or sig >= signal.NSIG) {
        return sys.ERROR;
    }
    const p: *proc.Proc = kern_proc.current;

    if (oact_ptr != 0) {
        const oact: *align(1) Sigaction = @ptrFromInt(oact_ptr);
        oact.handler = p.sig_handler[sig];
        oact.mask = 0;
    }
    if (act_ptr != 0) {
        const act: *align(1) const Sigaction = @ptrFromInt(act_ptr);
        p.sig_handler[sig] = act.handler;
    }
    return 0;
}

/// sigprocmask(2): get and/or set the blocked-signal mask.
pub fn sysSigprocmask(args: [sys.MAXARGS]u64) u64 {
    const set_ptr: u64 = args[1];
    const oset_ptr: u64 = args[2];
    const p: *proc.Proc = kern_proc.current;

    if (oset_ptr != 0) {
        const oset: *align(1) u64 = @ptrFromInt(oset_ptr);
        oset.* = p.sig_mask;
    }
    if (set_ptr != 0) {
        const set: *align(1) const u64 = @ptrFromInt(set_ptr);
        p.sig_mask = set.*;
    }
    return 0;
}

/// sigreturn(2): restore the context a signal handler interrupted.
pub fn sysSigreturn(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    const frame = arch.trap.currentFrame() orelse return sys.ERROR;
    const saved: *const arch.trapframe.TrapFrame = @ptrFromInt(frame.rsp);
    const rax: u64 = saved.rax;
    frame.* = saved.*;
    return rax;
}
