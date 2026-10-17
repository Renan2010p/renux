// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// User-space mutex support: _umtx_op(2).
//
// The counterpart of FreeBSD's sys/kern/kern_umtx.c. libthr (FreeBSD's
// threads library) keeps its locks, conditions and semaphores in user memory
// and only enters the kernel to sleep on an address whose value has not
// changed, or to wake the sleepers. A waiter sleeps until a wake on its
// address, a signal (EINTR) or its timeout (ETIMEDOUT).
//
// Waiters and wakers meet on a key naming the word, as FreeBSD's
// umtx_key_get does: for memory private to a process, the process and the
// word's virtual address. (Not its physical address: after a fork the page
// is copy-on-write, and the first write -- often the very write that
// releases the lock -- moves it to a new physical page, so a waker would
// look for the sleepers in the wrong place.) Renux has no memory shared
// between processes yet, so every key is private. A waiter always rechecks
// its condition after waking, so waking more threads than asked is
// harmless.

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
const UMTX_OP_RW_RDLOCK: u64 = 12;
const UMTX_OP_RW_WRLOCK: u64 = 13;
const UMTX_OP_RW_UNLOCK: u64 = 14;
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

/// struct urwlock: rw_state holds the reader count and the flags below.
const Urwlock: type = extern struct {
    rw_state: u32,
    rw_flags: u32,
    rw_blocked_readers: u32,
    rw_blocked_writers: u32,
    spare: [4]u32,
};
const URWLOCK_WRITE_OWNER: u32 = 0x80000000;
const URWLOCK_WRITE_WAITERS: u32 = 0x40000000;
const URWLOCK_READ_WAITERS: u32 = 0x20000000;
const URWLOCK_MAX_READERS: u32 = 0x1fffffff;
const URWLOCK_PREFER_READER: u32 = 0x0002;

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

/// The sleep channel for the user word at `addr` in the current process:
/// the pid in bits 47..62 above the virtual address (user addresses are
/// below 2^47), with bit 63 set so it can never equal a kernel object's
/// address, which other sleeps use.
fn channel(addr: u64) ?*anyopaque {
    const pid: u64 = @as(u64, @intCast(kern_proc.current.pid)) & 0xffff;
    return @ptrFromInt((1 << 63) | (pid << 47) | (addr & ((1 << 47) - 1)));
}

/// Wake the threads waiting on the user word at `addr` (`shared` is
/// accepted for symmetry with FreeBSD's calls: every key is private while
/// Renux has no shared memory).
pub fn wakeAddress(addr: u64, shared: bool) void {
    _ = shared;
    kern_sched.wakeup(channel(addr));
}

/// Sleep on the user word at `addr` while `stillWaiting()` holds, until a
/// wake on it, a signal or the deadline.
fn waitWhile(addr: u64, ctx: anytype, comptime stillWaiting: fn (@TypeOf(ctx)) bool, until: ?u64) u64 {
    while (stillWaiting(ctx)) {
        if (kern_signal.interrupted()) return sys.signed(-errno.EINTR);
        if (until) |d| {
            if (arch.clock.tickCount() >= d) return sys.signed(-errno.ETIMEDOUT);
        }
        kern_sched.sleepUntil(channel(addr), until orelse 0);
    }
    return 0;
}

// -- reader/writer locks -------------------------------------------------------
//
// The kernel half of libthr's pthread_rwlock: the user fast path takes and
// releases the lock with atomic operations on rw_state; when that fails it
// asks the kernel, which sleeps on the lock and wakes the waiters at unlock.
// One CPU and no preemption inside the kernel make each step atomic.

fn rwlock(addr: u64) *align(1) volatile Urwlock {
    return @ptrFromInt(addr);
}

/// Whether a reader may take the lock now (writers waiting hold readers
/// back, unless the lock prefers readers).
fn readerMayEnter(rw: *align(1) volatile Urwlock) bool {
    const state: u32 = rw.rw_state;
    if ((state & URWLOCK_WRITE_OWNER) != 0) return false;
    if ((state & URWLOCK_WRITE_WAITERS) != 0 and (rw.rw_flags & URWLOCK_PREFER_READER) == 0) return false;
    return true;
}

fn rwRdlock(addr: u64, until: ?u64) u64 {
    const rw = rwlock(addr);
    while (!readerMayEnter(rw)) {
        rw.rw_state |= URWLOCK_READ_WAITERS;
        rw.rw_blocked_readers += 1;
        const e: u64 = waitOnce(addr, until);
        rw.rw_blocked_readers -= 1;
        if (rw.rw_blocked_readers == 0) rw.rw_state &= ~URWLOCK_READ_WAITERS;
        if (e != 0) return e;
    }
    if ((rw.rw_state & URWLOCK_MAX_READERS) == URWLOCK_MAX_READERS) return sys.signed(-errno.EAGAIN);
    rw.rw_state += 1;
    return 0;
}

fn rwWrlock(addr: u64, until: ?u64) u64 {
    const rw = rwlock(addr);
    while ((rw.rw_state & URWLOCK_WRITE_OWNER) != 0 or (rw.rw_state & URWLOCK_MAX_READERS) != 0) {
        rw.rw_state |= URWLOCK_WRITE_WAITERS;
        rw.rw_blocked_writers += 1;
        const e: u64 = waitOnce(addr, until);
        rw.rw_blocked_writers -= 1;
        if (rw.rw_blocked_writers == 0) rw.rw_state &= ~URWLOCK_WRITE_WAITERS;
        if (e != 0) return e;
    }
    rw.rw_state |= URWLOCK_WRITE_OWNER;
    return 0;
}

fn rwUnlock(addr: u64) u64 {
    const rw = rwlock(addr);
    if ((rw.rw_state & URWLOCK_WRITE_OWNER) != 0) {
        rw.rw_state &= ~URWLOCK_WRITE_OWNER;
    } else if ((rw.rw_state & URWLOCK_MAX_READERS) != 0) {
        rw.rw_state -= 1;
    } else {
        return sys.signed(-errno.EPERM);
    }
    if ((rw.rw_state & (URWLOCK_READ_WAITERS | URWLOCK_WRITE_WAITERS)) != 0) wakeAddress(addr, true);
    return 0;
}

/// One sleep on `addr` for a lock: 0 when woken, else EINTR or ETIMEDOUT.
fn waitOnce(addr: u64, until: ?u64) u64 {
    if (kern_signal.interrupted()) return sys.signed(-errno.EINTR);
    if (until) |d| {
        if (arch.clock.tickCount() >= d) return sys.signed(-errno.ETIMEDOUT);
    }
    kern_sched.sleepUntil(channel(addr), until orelse 0);
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
            return waitWhile(obj, Word64{ .addr = obj, .val = val }, wordUnchanged, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_WAIT_UINT, UMTX_OP_WAIT_UINT_PRIVATE => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(obj, Word32{ .addr = obj, .val = @truncate(val) }, uintUnchanged, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_WAKE, UMTX_OP_WAKE_PRIVATE, UMTX_OP_MUTEX_WAKE2, UMTX_OP_SEM2_WAKE => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            wakeAddress(obj, op == UMTX_OP_WAKE);
            return 0;
        },
        UMTX_OP_NWAKE_PRIVATE => {
            // `obj` is an array of `val` addresses to wake.
            if (obj == 0) return sys.signed(-errno.EFAULT);
            const addrs: [*]align(1) const u64 = @ptrFromInt(obj);
            for (0..@intCast(val)) |i| wakeAddress(addrs[i], false);
            return 0;
        },
        UMTX_OP_MUTEX_WAIT => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(obj, obj, mutexOwned, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_SEM2_WAIT => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return waitWhile(obj, obj, semEmpty, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_RW_RDLOCK => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return rwRdlock(obj, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_RW_WRLOCK => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return rwWrlock(obj, deadline(uaddr2, uaddr1));
        },
        UMTX_OP_RW_UNLOCK => {
            if (obj == 0) return sys.signed(-errno.EFAULT);
            return rwUnlock(obj);
        },
        // Robust lists (cleaning up mutexes a dead thread held) are not
        // tracked; the minimum timeout is the clock tick.
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
