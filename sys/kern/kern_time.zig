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
pub fn setBoottime(now: i64) void {
    if (now <= 0) {
        return;
    }
    const up: u64 = arch.clock.tickCount() / arch.clock.HZ;
    boottime = @as(u64, @intCast(now)) -| up;
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
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_PRECISE, CLOCK_MONOTONIC_FAST, CLOCK_UPTIME, CLOCK_UPTIME_PRECISE, CLOCK_UPTIME_FAST, CLOCK_SECOND => {
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
