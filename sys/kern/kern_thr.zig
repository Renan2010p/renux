// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Thread calls.
//
// The Zig counterpart of the single-thread part of FreeBSD's
// sys/kern/kern_thr.c. Renux processes have exactly one thread, whose id is
// the pid offset into FreeBSD's thread-id range (FreeBSD numbers threads from
// 100000 up, apart from pids). libc asks for it even in programs that never
// create threads: raise(3) and abort(3) signal the calling thread.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const signal: type = @import("../sys/signal.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_sched: type = @import("kern_sched.zig");
const arch: type = @import("../arch/arch.zig");
const kern_time: type = @import("kern_time.zig");

/// First thread id.
pub const TID_BASE: i64 = 100000;

/// The id of the only thread of process `pid`.
pub fn tidOf(pid: i32) i64 {
    return TID_BASE + pid;
}

/// thr_self(2): `thr_self(long *id)`.
pub fn sysThrSelf(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const dst: *align(1) i64 = @ptrFromInt(args[0]);
    dst.* = tidOf(kern_proc.current.pid);
    return 0;
}

/// thr_kill(2): `thr_kill(long id, int sig)`; only the calling thread exists.
pub fn sysThrKill(args: [sys.MAXARGS]u64) u64 {
    const id: i64 = @bitCast(args[0]);
    const sig: u64 = args[1];
    const p = kern_proc.current;
    if (id != tidOf(p.pid) and id != -1) return sys.signed(-errno.ESRCH);
    if (sig >= signal.NSIG) return sys.signed(-errno.EINVAL);
    if (sig != 0) kern_signal.psignal(p, @intCast(sig));
    return 0;
}

/// thr_wake(2): wake the thread `id` from thr_suspend(2) (or make its next
/// thr_suspend return at once).
pub fn sysThrWake(args: [sys.MAXARGS]u64) u64 {
    const id: i64 = @bitCast(args[0]);
    const p = kern_proc.current;
    if (id != tidOf(p.pid)) return sys.signed(-errno.ESRCH);
    p.thr_woken = true;
    kern_sched.ioWakeup();
    return 0;
}

/// thr_suspend(2): `thr_suspend(const struct timespec *timeout)`; sleep until
/// thr_wake(2), a signal or the timeout.
pub fn sysThrSuspend(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    var until: ?u64 = null;
    if (args[0] != 0) {
        const ts: *align(1) const kern_time.Timespec = @ptrFromInt(args[0]);
        const hz: u64 = arch.clock.HZ;
        until = arch.clock.tickCount() + @as(u64, @intCast(@max(ts.tv_sec, 0))) * hz +
            @as(u64, @intCast(@max(ts.tv_nsec, 0))) * hz / 1_000_000_000;
    }
    while (!p.thr_woken) {
        if (kern_signal.interrupted(p)) return sys.signed(-errno.EINTR);
        if (until) |d| {
            if (arch.clock.tickCount() >= d) return sys.signed(-errno.ETIMEDOUT);
        }
        kern_sched.ioWait();
    }
    p.thr_woken = false;
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
