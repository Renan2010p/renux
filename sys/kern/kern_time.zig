// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Time of day.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_time.c, reduced to
// gettimeofday(2). There is no real-time clock yet, so the time is the boot
// epoch plus the ticks the system clock has counted since boot.

const sys: type = @import("../sys/syscall.zig");
const arch: type = @import("../arch/arch.zig");

/// Seconds at boot, 2026-01-01T00:00:00Z (there is no RTC to read).
const EPOCH: u64 = 1767225600;

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
        tv.tv_sec = @intCast(EPOCH + ticks / hz);
        tv.tv_usec = @intCast((ticks % hz) * (1_000_000 / hz));
    }
    return 0;
}
