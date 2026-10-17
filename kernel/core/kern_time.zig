// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Time of day.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_time.c, reduced to
// gettimeofday(2). The time is the boot time, read from the real-time clock at
// boot (arch/x86/isa/atrtc.zig), plus the ticks the system clock has counted
// since.

const sys: type = @import("../sys/syscall.zig");
const arch: type = @import("../arch/arch.zig");
const errno: type = @import("../sys/errno.zig");

/// Boot time used when no real-time clock can be read, 2026-01-01T00:00:00Z.
const DEFAULT_BOOTTIME: u64 = 1767225600;

/// Seconds since the epoch at boot (FreeBSD's boottime). Published so sysctl
/// kern.boottime reports it and uptime is measured from boot.
pub var boottime: u64 = DEFAULT_BOOTTIME;

/// Set the time of day to `now` seconds since the epoch, as FreeBSD's
/// inittodr() does from the RTC: the boot time is `now` less the uptime.
pub fn setBoottime(tod: i64) void {
    if (tod <= 0) {
        return;
    }
    const up: u64 = arch.clock.tickCount() / arch.clock.HZ;
    boottime = @as(u64, @intCast(tod)) -| up;
}

/// The current time of day, in seconds since the epoch.
pub fn now() u64 {
    return boottime + arch.clock.tickCount() / arch.clock.HZ;
}

/// A time value (NetBSD's struct timeval).
pub const Timeval: type = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// gettimeofday(2): fill in the current time, ignoring the timezone argument.
pub fn sysGettimeofday(args: [sys.MAXARGS]u64) u64 {
    const tv_ptr: u64 = args[0];
    const ticks: u64 = arch.clock.tickCount();
    const hz: u64 = arch.clock.HZ;

    if (tv_ptr != 0) {
        const tv: *Timeval = @ptrFromInt(tv_ptr);
        tv.tv_sec = @intCast(boottime + ticks / hz);
        tv.tv_usec = @intCast((ticks % hz) * (1_000_000 / hz));
    }
    return 0;
}

/// A clock value (FreeBSD's struct timespec).
pub const Timespec: type = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const CLOCK_REALTIME: u64 = 0;
const CLOCK_REALTIME_PRECISE: u64 = 1;
const CLOCK_MONOTONIC: u64 = 4;
const CLOCK_UPTIME: u64 = 5;
const CLOCK_UPTIME_PRECISE: u64 = 7;
const CLOCK_UPTIME_FAST: u64 = 8;
const CLOCK_REALTIME_FAST: u64 = 10;
const CLOCK_MONOTONIC_PRECISE: u64 = 11;
const CLOCK_MONOTONIC_FAST: u64 = 12;
const CLOCK_SECOND: u64 = 13;

/// clock_gettime(2): fill in the requested clock's current value.
pub fn sysClockGettime(args: [sys.MAXARGS]u64) u64 {
    const clockid: u64 = args[0];
    const tp: u64 = args[1];
    const ticks: u64 = arch.clock.tickCount();
    const hz: u64 = arch.clock.HZ;

    var sec: i64 = 0;
    var nsec: i64 = 0;
    switch (clockid) {
        CLOCK_REALTIME, CLOCK_REALTIME_PRECISE, CLOCK_REALTIME_FAST => {
            sec = @intCast(boottime + ticks / hz);
            nsec = @intCast((ticks % hz) * (1_000_000_000 / hz));
        },
        // CLOCK_SECOND is the time of day in whole seconds (time(3) uses it).
        CLOCK_SECOND => {
            sec = @intCast(boottime + ticks / hz);
            nsec = 0;
        },
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_PRECISE, CLOCK_MONOTONIC_FAST, CLOCK_UPTIME, CLOCK_UPTIME_PRECISE, CLOCK_UPTIME_FAST => {
            sec = @intCast(ticks / hz);
            nsec = @intCast((ticks % hz) * (1_000_000_000 / hz));
        },
        else => return sys.signed(-errno.EINVAL),
    }
    if (tp != 0) {
        const ts: *align(1) Timespec = @ptrFromInt(tp);
        ts.tv_sec = sec;
        ts.tv_nsec = nsec;
    }
    return 0;
}

// -- sleeping and interval timers ------------------------------------------------
//
// FreeBSD's kern_time.c: nanosleep(2) and the ITIMER_REAL interval timer
// behind setitimer(2) and alarm(3), driven by the clock tick (hardclock).

const proc: type = @import("../sys/proc.zig");
const signal: type = @import("../sys/signal.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_resource: type = @import("kern_resource.zig");

/// Called on every clock tick: fire the interval timers that are due.
pub fn hardclock(ticks: u64) void {
    // Charge the tick to the running thread's process, as user or system
    // time (FreeBSD's statclock), and look at its resident set once a
    // second -- only when it was interrupted in user mode, so that its page
    // tables are not halfway through a change.
    if (!kern_sched.in_scheduler) {
        const p: *proc.Proc = kern_proc.curthread.proc;
        if (arch.trap.intr_from_user) {
            p.usage.uticks += 1;
            if (ticks % arch.clock.HZ == 0) kern_resource.sampleRss(p);
        } else {
            p.usage.sticks += 1;
        }
    }
    for (&kern_proc.table) |*p| {
        if (p.state == .unused or p.state == .zombie or p.itimer_due == 0) continue;
        if (ticks < p.itimer_due) continue;
        p.itimer_due = if (p.itimer_interval != 0) ticks + p.itimer_interval else 0;
        // psignal wakes the thread that takes it if it waits in the kernel.
        kern_signal.psignal(p, signal.SIGALRM);
    }
    kern_sched.wakeTimedOut(ticks);
}

const USEC_PER_TICK: u64 = 1_000_000 / arch.clock.HZ;

fn tvToTicks(tv: Timeval) u64 {
    if (tv.tv_sec < 0 or tv.tv_usec < 0) return 0;
    const us: u64 = @as(u64, @intCast(tv.tv_sec)) * 1_000_000 + @as(u64, @intCast(tv.tv_usec));
    return (us + USEC_PER_TICK - 1) / USEC_PER_TICK;
}

fn ticksToTv(t: u64) Timeval {
    const us: u64 = t * USEC_PER_TICK;
    return .{ .tv_sec = @intCast(us / 1_000_000), .tv_usec = @intCast(us % 1_000_000) };
}

/// struct itimerval.
const Itimerval: type = extern struct {
    it_interval: Timeval,
    it_value: Timeval,
};

const ITIMER_REAL: u64 = 0;

fn currentItimer(p: *proc.Proc) Itimerval {
    const now_t: u64 = arch.clock.tickCount();
    const left: u64 = if (p.itimer_due > now_t) p.itimer_due - now_t else 0;
    return .{ .it_interval = ticksToTv(p.itimer_interval), .it_value = ticksToTv(if (p.itimer_due == 0) 0 else left) };
}

/// getitimer(2). Only ITIMER_REAL runs; the virtual and profiling timers
/// (which need per-process CPU accounting) are refused.
pub fn sysGetitimer(args: [sys.MAXARGS]u64) u64 {
    if (args[0] != ITIMER_REAL) return sys.signed(-errno.EINVAL);
    const dst: *align(1) Itimerval = @ptrFromInt(args[1]);
    dst.* = currentItimer(kern_proc.current);
    return 0;
}

/// setitimer(2): arm or disarm ITIMER_REAL, returning the old setting.
pub fn sysSetitimer(args: [sys.MAXARGS]u64) u64 {
    if (args[0] != ITIMER_REAL) return sys.signed(-errno.EINVAL);
    const p = kern_proc.current;
    if (args[2] != 0) {
        const old: *align(1) Itimerval = @ptrFromInt(args[2]);
        old.* = currentItimer(p);
    }
    if (args[1] == 0) return 0;
    const new: *align(1) const Itimerval = @ptrFromInt(args[1]);
    const v: u64 = tvToTicks(new.it_value);
    p.itimer_interval = tvToTicks(new.it_interval);
    p.itimer_due = if (v == 0) 0 else arch.clock.tickCount() + v;
    return 0;
}

/// nanosleep(2): sleep for the requested time, in clock ticks. A pending
/// signal cuts it short with EINTR and the time left in `rmtp`.
pub fn sysNanosleep(args: [sys.MAXARGS]u64) u64 {
    const rq: *align(1) const Timespec = @ptrFromInt(args[0]);
    if (rq.tv_sec < 0 or rq.tv_nsec < 0 or rq.tv_nsec >= 1_000_000_000) return sys.signed(-errno.EINVAL);
    const ns: u64 = @as(u64, @intCast(rq.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(rq.tv_nsec));
    const ns_per_tick: u64 = 1_000_000_000 / arch.clock.HZ;
    const due: u64 = arch.clock.tickCount() + (ns + ns_per_tick - 1) / ns_per_tick;
    while (arch.clock.tickCount() < due) {
        if (kern_signal.interrupted()) {
            if (args[1] != 0) {
                const left: u64 = (due - arch.clock.tickCount()) * ns_per_tick;
                const rm: *align(1) Timespec = @ptrFromInt(args[1]);
                rm.* = .{ .tv_sec = @intCast(left / 1_000_000_000), .tv_nsec = @intCast(left % 1_000_000_000) };
            }
            return sys.signed(-errno.EINTR);
        }
        kern_sched.sleep(arch.clock.pollChannel());
    }
    return 0;
}

// -- scheduling priority ---------------------------------------------------------

/// getpriority(2): the nice value. FreeBSD returns it directly (it may be
/// negative; libc tells it from an error by errno).
pub fn sysGetpriority(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @bitCast(@as(i64, kern_proc.current.nice));
}

/// setpriority(2): record the nice value of the calling process. Only root
/// may lower it.
pub fn sysSetpriority(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    const prio: i64 = @as(i32, @bitCast(@as(u32, @truncate(args[2]))));
    const clamped: i32 = @intCast(@max(-20, @min(20, prio)));
    if (clamped < p.nice and p.euid != 0) return sys.signed(-errno.EACCES);
    p.nice = clamped;
    return 0;
}

/// clock_getres(2): every clock advances by one tick.
pub fn sysClockGetres(args: [sys.MAXARGS]u64) u64 {
    if (args[0] > 15) return sys.signed(-errno.EINVAL);
    if (args[1] != 0) {
        const ts: *align(1) Timespec = @ptrFromInt(args[1]);
        ts.* = .{ .tv_sec = 0, .tv_nsec = @intCast(1_000_000_000 / arch.clock.HZ) };
    }
    return 0;
}
