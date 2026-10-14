// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// User-space mutex support: _umtx_op(2).
//
// The counterpart of FreeBSD's sys/kern/kern_umtx.c. libthr (FreeBSD's
// threads library, which libintl and so bash and nano load) keeps its locks,
// conditions and semaphores in user memory and only enters the kernel to
// sleep on an address whose value has not changed, or to wake the sleepers.
// Renux processes have one thread, so these are mostly uncontended; the
// operations still behave as FreeBSD's do, waking on the address, on a
// signal (EINTR) or at a timeout (ETIMEDOUT).

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_time: type = @import("kern_time.zig");

// Operations (FreeBSD's sys/umtx.h).
const UMTX_OP_WAIT: u64 = 2;
const UMTX_OP_WAKE: u64 = 3;
const UMTX_OP_MUTEX_TRYLOCK: u64 = 4;
const UMTX_OP_MUTEX_LOCK: u64 = 5;
const UMTX_OP_MUTEX_UNLOCK: u64 = 6;
const UMTX_OP_WAIT_UINT: u64 = 11;
const UMTX_OP_WAIT_UINT_PRIVATE: u64 = 15;
const UMTX_OP_WAKE_PRIVATE: u64 = 16;
const UMTX_OP_MUTEX_WAIT: u64 = 17;
const UMTX_OP_NWAKE_PRIVATE: u64 = 21;
const UMTX_OP_MUTEX_WAKE2: u64 = 22;
const UMTX_OP_SEM2_WAIT: u64 = 23;
const UMTX_OP_SEM2_WAKE: u64 = 24;
const UMTX_OP_ROBUST_LISTS: u64 = 26;
const UMTX_OP_GET_MIN_TIMEOUT: u64 = 27;
const UMTX_OP_SET_MIN_TIMEOUT: u64 = 28;

const UMUTEX_UNOWNED: u32 = 0;
const UMUTEX_CONTESTED: u32 = 0x80000000;
const USEM_HAS_WAITERS: u32 = 0x80000000;

/// struct _umtx_time: a timeout, relative unless UMTX_ABSTIME is set.
const UmtxTime: type = extern struct {
    sec: i64,
    nsec: i64,
    flags: u32,
    clockid: u32,
};
const UMTX_ABSTIME: u32 = 0x01;

/// The tick at which a wait with the timeout in (`uaddr`, `size`) ends, or
/// null for no timeout. FreeBSD passes either a struct timespec or a struct
/// _umtx_time, telling them apart by `size`.
fn deadline(uaddr: u64, size: u64) ?u64 {
    if (uaddr == 0) return null;
    const hz: u64 = arch.clock.HZ;
    const now_ticks: u64 = arch.clock.tickCount();
    var sec: i64 = undefined;
    var nsec: i64 = undefined;
    var abs: bool = false;
    if (size >= @sizeOf(UmtxTime)) {
        const t: *align(1) const UmtxTime = @ptrFromInt(uaddr);
        sec = t.sec;
        nsec = t.nsec;
        abs = (t.flags & UMTX_ABSTIME) != 0;
    } else {
        const t: *align(1) const kern_time.Timespec = @ptrFromInt(uaddr);
        sec = t.tv_sec;
        nsec = t.tv_nsec;
    }
    if (sec < 0) return now_ticks;
    var ticks: u64 = @as(u64, @intCast(sec)) * hz + @as(u64, @intCast(@max(nsec, 0))) * hz / 1_000_000_000;
    if (abs) {
        // Absolute against the realtime clock (the usual clockid for libthr).
        const now: u64 = kern_time.now();
        const s: u64 = @intCast(sec);
        ticks = if (s > now) (s - now) * hz else 0;
    }
    return now_ticks + ticks + 1;
}

/// Sleep while `stillWaiting()` holds, for a wake, a signal or the deadline.
fn waitWhile(ctx: anytype, comptime stillWaiting: fn (@TypeOf(ctx)) bool, until: ?u64) u64 {
    const p = kern_proc.current;
    while (stillWaiting(ctx)) {
        if (kern_signal.interrupted(p)) return sys.signed(-errno.EINTR);
        if (until) |d| {
            if (arch.clock.tickCount() >= d) return sys.signed(-errno.ETIMEDOUT);
        }
        kern_sched.ioWait();
    }
    return 0;
}

const Word64: type = struct { addr: u64, val: u64 };
fn wordUnchanged(w: Word64) bool {
    return @as(*align(1) const volatile u64, @ptrFromInt(w.addr)).* == w.val;
}

const Word32: type = struct { addr: u64, val: u32 };
fn uintUnchanged(w: Word32) bool {
    return @as(*align(1) const volatile u32, @ptrFromInt(w.addr)).* == w.val;
}

fn mutexOwned(addr: u64) bool {
    const owner: *align(1) volatile u32 = @ptrFromInt(addr);
    const v: u32 = owner.*;
    if ((v & ~UMUTEX_CONTESTED) == UMUTEX_UNOWNED) return false;
    owner.* = v | UMUTEX_CONTESTED; // tell the owner to wake us on unlock
    return true;
}

fn semEmpty(addr: u64) bool {
    const count: *align(1) volatile u32 = @ptrFromInt(addr);
    const v: u32 = count.*;
    if ((v & ~USEM_HAS_WAITERS) != 0) return false;
    count.* = v | USEM_HAS_WAITERS;
    return true;
}

/// _umtx_op(2): `_umtx_op(obj, op, val, uaddr1, uaddr2)`.
pub fn sysUmtxOp(args: [sys.MAXARGS]u64) u64 {
    const obj: u64 = args[0];
    const op: u64 = args[1];
    const val: u64 = args[2];
    const uaddr1: u64 = args[3];
    const uaddr2: u64 = args[4];
    switch (op) {
        UMTX_OP_WAIT => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(Word64{ .addr = obj, .val = val }, wordUnchanged, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_WAIT_UINT, UMTX_OP_WAIT_UINT_PRIVATE => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(Word32{ .addr = obj, .val = @truncate(val) }, uintUnchanged, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_WAKE, UMTX_OP_WAKE_PRIVATE, UMTX_OP_NWAKE_PRIVATE, UMTX_OP_MUTEX_WAKE2, UMTX_OP_SEM2_WAKE => {
            // Every waiter rechecks its own condition, so one wake serves
            // all of these.
            kern_sched.ioWakeup();
            return 0;
        },
        UMTX_OP_MUTEX_WAIT => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(obj, mutexOwned, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_SEM2_WAIT => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(obj, semEmpty, deadline(uaddr2, uaddr1));
        },
        // With one thread per process a robust-list registration has
        // nothing to track, and the minimum timeout is the tick.
        UMTX_OP_ROBUST_LISTS, UMTX_OP_SET_MIN_TIMEOUT => return 0,
        UMTX_OP_GET_MIN_TIMEOUT => {
            if (uaddr1 != 0) @as(*align(1) i64, @ptrFromInt(uaddr1)).* = 0;
            return 0;
        },
        // Kernel-managed mutexes (priority protocols): not supported yet.
        UMTX_OP_MUTEX_TRYLOCK, UMTX_OP_MUTEX_LOCK, UMTX_OP_MUTEX_UNLOCK => return sys.signed(-errno.EOPNOTSUPP),
        else => return sys.signed(-errno.EINVAL),
    }
}
