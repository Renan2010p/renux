// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Thread calls.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_thr.c: the system calls
// FreeBSD's threads library (libthr) is built on. pthread_create(3) calls
// thr_new(2), pthread_exit(3) thr_exit(2), pthread_kill(3) thr_kill(2), and
// pthread_join(3) waits with _umtx_op(2) on the word thr_exit(2) clears.
//
// Thread ids start at 100000 (kern_proc.TID_BASE), apart from pids.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const signal: type = @import("../sys/signal.zig");
const proc: type = @import("../sys/proc.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_exit: type = @import("kern_exit.zig");
const kern_umtx: type = @import("kern_umtx.zig");
const arch: type = @import("../arch/arch.zig");
const kern_time: type = @import("kern_time.zig");

/// The highest user address (FreeBSD/amd64's VM_MAXUSER_ADDRESS).
const VM_MAXUSER_ADDRESS: u64 = 0x0000_7fff_ffff_f000;

/// struct thr_param, as thr_new(2) receives it.
const ThrParam: type = extern struct {
    /// The function the thread starts in, and its argument.
    start_func: u64,
    arg: u64,
    /// The thread's user stack.
    stack_base: u64,
    stack_size: u64,
    /// The thread's TLS block (its thread pointer) and size.
    tls_base: u64,
    tls_size: u64,
    /// Where to store the new thread's id, for the child and the parent.
    child_tid: u64,
    parent_tid: u64,
    flags: i32,
    /// Real-time priority (struct rtprio *); Renux runs every thread in the
    /// time-sharing class.
    rtp: u64,
    spare: [3]u64,
};

comptime {
    const checks: type = @import("../sys/checks.zig");
    checks.assertSize(ThrParam, 104);
    checks.assertOffsetOf(ThrParam, "flags", 64);
}

/// thr_new(2): `thr_new(struct thr_param *param, int param_size)`. Start a
/// thread in the calling process at `start_func(arg)`, on the given stack
/// and with the given thread pointer, the way FreeBSD's cpu_set_upcall does.
/// The new thread's id is stored at `child_tid` and `parent_tid`.
pub fn sysThrNew(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    if (args[1] < @sizeOf(ThrParam)) return sys.signed(-errno.EINVAL);
    const param: ThrParam = @as(*align(1) const ThrParam, @ptrFromInt(args[0])).*;
    if (param.start_func == 0 or param.start_func >= VM_MAXUSER_ADDRESS) return sys.signed(-errno.EINVAL);
    if (param.tls_base >= VM_MAXUSER_ADDRESS) return sys.signed(-errno.EINVAL);

    const caller: *proc.Thread = kern_proc.curthread;
    const caller_frame: *arch.trapframe.TrapFrame = arch.trap.currentFrame() orelse return sys.signed(-errno.EINVAL);
    const td: *proc.Thread = kern_proc.threadAlloc(caller.proc) orelse return sys.signed(-errno.EPROCLIM);

    // The user frame: the thread enters start_func(arg) as if called, with
    // its stack 16-byte aligned before the (absent) return address.
    td.frame = caller_frame.*;
    td.frame.rip = param.start_func;
    td.frame.rdi = param.arg;
    td.frame.rsp = ((param.stack_base + param.stack_size) & ~@as(u64, 0xf)) - 8;
    td.frame.rax = 0;
    td.frame.rflags &= ~@as(u64, 1);
    td.fsbase = param.tls_base;
    // A new thread starts with its creator's signal mask (FreeBSD).
    td.sig_mask = caller.sig_mask;

    if (param.child_tid != 0) @as(*align(1) i64, @ptrFromInt(param.child_tid)).* = td.tid;
    if (param.parent_tid != 0) @as(*align(1) i64, @ptrFromInt(param.parent_tid)).* = td.tid;

    kern_sched.prepareContext(td);
    td.state = .runnable;
    return 0;
}

/// thr_exit(2): `thr_exit(long *state)`. End the calling thread. When
/// `state` is given, 1 is stored there and the threads waiting on it with
/// _umtx_op(2) are woken (pthread_join). The last thread's exit ends the
/// process with status 0.
pub fn sysThrExit(args: [sys.MAXARGS]u64) u64 {
    const p: *proc.Proc = kern_proc.current;
    if (args[0] != 0) {
        @as(*align(1) volatile i64, @ptrFromInt(args[0])).* = 1;
        kern_umtx.wakeAddress(args[0], true);
    }
    if (p.nthreads <= 1) kern_exit.exit(0);
    kern_exit.threadExit();
}

/// thr_self(2): `thr_self(long *id)`.
pub fn sysThrSelf(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    @as(*align(1) i64, @ptrFromInt(args[0])).* = kern_proc.curthread.tid;
    return 0;
}

/// thr_kill(2): `thr_kill(long id, int sig)`; `id` -1 signals every thread
/// of the process.
pub fn sysThrKill(args: [sys.MAXARGS]u64) u64 {
    const id: i64 = @bitCast(args[0]);
    const sig: u64 = args[1];
    if (sig >= signal.NSIG) return sys.signed(-errno.EINVAL);
    const p: *proc.Proc = kern_proc.current;
    if (id == -1) {
        if (sig != 0) {
            for (&kern_proc.threads) |*td| {
                if (td.state != .unused and td.state != .dead and td.proc == p) kern_signal.tdsignal(td, @intCast(sig));
            }
        }
        return 0;
    }
    const target: *proc.Thread = kern_proc.tfind(p, id) orelse return sys.signed(-errno.ESRCH);
    if (sig != 0) kern_signal.tdsignal(target, @intCast(sig));
    return 0;
}

/// thr_kill2(2): `thr_kill2(pid_t pid, long id, int sig)`, thr_kill for a
/// thread of process `pid`.
pub fn sysThrKill2(args: [sys.MAXARGS]u64) u64 {
    const pid: i32 = @bitCast(@as(u32, @truncate(args[0])));
    const id: i64 = @bitCast(args[1]);
    const sig: u64 = args[2];
    if (sig >= signal.NSIG) return sys.signed(-errno.EINVAL);
    const p: *proc.Proc = kern_proc.pfind(pid) orelse return sys.signed(-errno.ESRCH);
    const target: *proc.Thread = kern_proc.tfind(p, id) orelse return sys.signed(-errno.ESRCH);
    if (sig != 0) kern_signal.tdsignal(target, @intCast(sig));
    return 0;
}

/// thr_wake(2): `thr_wake(long id)`; wake thread `id` of the calling
/// process from thr_suspend(2), or make its next thr_suspend return at once.
pub fn sysThrWake(args: [sys.MAXARGS]u64) u64 {
    const id: i64 = @bitCast(args[0]);
    const target: *proc.Thread = kern_proc.tfind(kern_proc.current, id) orelse return sys.signed(-errno.ESRCH);
    target.thr_woken = true;
    kern_sched.wakeup(@ptrCast(&target.thr_woken));
    return 0;
}

/// thr_suspend(2): `thr_suspend(const struct timespec *timeout)`; sleep until
/// thr_wake(2), a signal or the timeout.
pub fn sysThrSuspend(args: [sys.MAXARGS]u64) u64 {
    const td: *proc.Thread = kern_proc.curthread;
    var until: u64 = 0;
    if (args[0] != 0) {
        const ts: *align(1) const kern_time.Timespec = @ptrFromInt(args[0]);
        const hz: u64 = arch.clock.HZ;
        until = arch.clock.tickCount() + 1 + @as(u64, @intCast(@max(ts.tv_sec, 0))) * hz +
            @as(u64, @intCast(@max(ts.tv_nsec, 0))) * hz / 1_000_000_000;
    }
    while (!td.thr_woken) {
        if (kern_signal.interrupted()) return sys.signed(-errno.EINTR);
        if (until != 0 and arch.clock.tickCount() >= until) return sys.signed(-errno.ETIMEDOUT);
        kern_sched.sleepUntil(@ptrCast(&td.thr_woken), until);
    }
    td.thr_woken = false;
    return 0;
}

/// thr_set_name(2): `thr_set_name(long id, const char *name)`; name a
/// thread of the calling process (for debuggers and ps -H).
pub fn sysThrSetName(args: [sys.MAXARGS]u64) u64 {
    const id: i64 = @bitCast(args[0]);
    const target: *proc.Thread = kern_proc.tfind(kern_proc.current, id) orelse return sys.signed(-errno.ESRCH);
    target.name = @splat(0);
    if (args[1] != 0) {
        const name: [*]const u8 = @ptrFromInt(args[1]);
        var i: usize = 0;
        while (i < target.name.len - 1 and name[i] != 0) : (i += 1) target.name[i] = name[i];
    }
    return 0;
}

/// sched_yield(2): let the other runnable threads run first.
pub fn sysSchedYield(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    kern_sched.yield();
    return 0;
}

/// struct rtprio.
const Rtprio: type = extern struct {
    type: u16,
    prio: u16,
};
const RTP_LOOKUP: u64 = 0;
const RTP_SET: u64 = 1;
const RTP_PRIO_NORMAL: u16 = 3;

/// rtprio_thread(2): `rtprio_thread(function, lwpid, rtp)`. Renux schedules
/// every thread in the normal (time-sharing) class; asking for another
/// class is refused.
pub fn sysRtprioThread(args: [sys.MAXARGS]u64) u64 {
    if (args[2] == 0) return sys.signed(-errno.EFAULT);
    const rtp: *align(1) Rtprio = @ptrFromInt(args[2]);
    switch (args[0]) {
        RTP_LOOKUP => {
            rtp.* = .{ .type = RTP_PRIO_NORMAL, .prio = 0 };
            return 0;
        },
        RTP_SET => return if (rtp.type == RTP_PRIO_NORMAL) 0 else sys.signed(-errno.EPERM),
        else => return sys.signed(-errno.EINVAL),
    }
}
