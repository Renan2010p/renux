// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// poll(2).
//
// This is the Zig counterpart of NetBSD's sys/kern/sys_poll.c: report the
// readiness of each descriptor (through its FileOps.poll, such as a pipe's;
// the console's input for devices without one; regular files always ready),
// and wait until one is ready or the timeout elapses. The timeout is measured with the system
// tick, and poll() sleeps on the clock's poll channel, which every tick wakes
// so the wait can be re-checked.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const cons: type = @import("../dev/cons.zig");
const arch: type = @import("../arch/arch.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const file: type = @import("../sys/file.zig");
const proc: type = @import("../sys/proc.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_time: type = @import("kern_time.zig");

/// Largest pollfd array accepted.
const MAXPOLL: usize = 256;

/// struct pollfd { int fd; short events; short revents; } -- eight bytes.
const POLLFD_SIZE: usize = 8;

fn load32(p: [*]const u8, off: usize) u32 {
    return @as(u32, p[off]) | (@as(u32, p[off + 1]) << 8) |
        (@as(u32, p[off + 2]) << 16) | (@as(u32, p[off + 3]) << 24);
}

fn load16(p: [*]const u8, off: usize) u16 {
    return @as(u16, p[off]) | (@as(u16, p[off + 1]) << 8);
}

fn store16(p: [*]u8, off: usize, v: u16) void {
    p[off] = @truncate(v);
    p[off + 1] = @truncate(v >> 8);
}

/// The poll(2) events of `fd` that hold now, among `events` (POLLHUP,
/// POLLERR and POLLNVAL are always reported).
fn readiness(fd: i32, events: i16) i16 {
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(fd)) orelse return @bitCast(file.POLLNVAL);
    const always: u16 = file.POLLHUP | file.POLLERR | file.POLLNVAL;
    const want: u16 = @as(u16, @bitCast(events)) | always;
    var ev: u16 = 0;
    if (f.f_ops.poll) |pollfn| {
        ev = pollfn(f);
    } else if (f.f_type == file.DTYPE_VNODE) {
        // Regular files and directories never block.
        ev = file.POLLIN | file.POLLOUT;
    } else {
        // Devices: the console is the only one with input to wait for.
        if (cons.cnInputReady()) ev |= file.POLLIN;
        ev |= file.POLLOUT;
    }
    return @bitCast(ev & want);
}

/// poll(2): wait for one of `nfds` descriptors to become ready.
pub fn sysPoll(args: [sys.MAXARGS]u64) u64 {
    const fds_ptr: u64 = args[0];
    const nfds: u64 = args[1];
    const timeout_ms: i32 = @bitCast(@as(u32, @truncate(args[2])));

    if (nfds > MAXPOLL) {
        return sys.signed(-errno.EINVAL);
    }
    if (nfds != 0 and fds_ptr == 0) {
        return sys.signed(-errno.EFAULT);
    }
    const n: usize = @intCast(nfds);
    const p: [*]u8 = @ptrFromInt(fds_ptr);
    const start: u64 = arch.clock.tickCount();

    while (true) {
        var ready: u64 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const base: usize = i * POLLFD_SIZE;
            const fd: i32 = @bitCast(load32(p, base));
            const events: i16 = @bitCast(load16(p, base + 4));
            var revents: i16 = 0;
            if (fd >= 0) {
                revents = readiness(fd, events);
            }
            store16(p, base + 6, @bitCast(revents));
            if (revents != 0) {
                ready += 1;
            }
        }
        if (ready > 0 or timeout_ms == 0) {
            return ready;
        }
        if (timeout_ms > 0) {
            const elapsed_ticks: u64 = arch.clock.tickCount() - start;
            if (elapsed_ticks * 1000 >= @as(u64, @intCast(timeout_ms)) * arch.clock.HZ) {
                return 0;
            }
        }
        // Sleep until the next tick (or input) and re-check.
        kern_sched.sleep(arch.clock.pollChannel());
    }
}

// -- select(2) and pselect(2) ----------------------------------------------------
//
// Same readiness as poll(2), on FreeBSD's fd_set bitmaps (arrays of 64-bit
// words), as in FreeBSD's sys_generic.c kern_select().

const fd_set_bits: usize = 64;

fn fdIsSet(set: u64, fd: usize) bool {
    if (set == 0) return false;
    const words: [*]align(1) const u64 = @ptrFromInt(set);
    return (words[fd / fd_set_bits] >> @intCast(fd % fd_set_bits)) & 1 != 0;
}

fn fdZeroUpTo(set: u64, nd: usize) void {
    if (set == 0) return;
    const words: [*]align(1) u64 = @ptrFromInt(set);
    var i: usize = 0;
    while (i * fd_set_bits < nd) : (i += 1) words[i] = 0;
}

fn fdSet(set: u64, fd: usize) void {
    const words: [*]align(1) u64 = @ptrFromInt(set);
    words[fd / fd_set_bits] |= @as(u64, 1) << @intCast(fd % fd_set_bits);
}

/// The common body: `until` is the tick deadline (null: wait forever).
fn selectCommon(nd_in: u64, rd: u64, wr: u64, ex: u64, until: ?u64) u64 {
    const p = kern_proc.current;
    const nd: usize = @intCast(@min(nd_in, proc.NFILE));
    // Snapshot the requested sets: the user's are overwritten with results.
    var want_r: [proc.NFILE]bool = @splat(false);
    var want_w: [proc.NFILE]bool = @splat(false);
    var fd: usize = 0;
    while (fd < nd) : (fd += 1) {
        want_r[fd] = fdIsSet(rd, fd);
        want_w[fd] = fdIsSet(wr, fd);
        if ((want_r[fd] or want_w[fd]) and kern_descrip.fdGetfile(p, fd) == null) return sys.signed(-errno.EBADF);
    }
    while (true) {
        var ready: u64 = 0;
        var got_r: [proc.NFILE]bool = @splat(false);
        var got_w: [proc.NFILE]bool = @splat(false);
        fd = 0;
        while (fd < nd) : (fd += 1) {
            if (!want_r[fd] and !want_w[fd]) continue;
            const ev: u16 = @bitCast(readiness(@intCast(fd), @bitCast(@as(u16, file.POLLIN | file.POLLOUT))));
            if (want_r[fd] and (ev & (file.POLLIN | file.POLLHUP)) != 0) {
                got_r[fd] = true;
                ready += 1;
            }
            if (want_w[fd] and (ev & (file.POLLOUT | file.POLLERR)) != 0) {
                got_w[fd] = true;
                ready += 1;
            }
        }
        const timed_out: bool = if (until) |d| arch.clock.tickCount() >= d else false;
        if (ready > 0 or timed_out) {
            fdZeroUpTo(rd, nd);
            fdZeroUpTo(wr, nd);
            fdZeroUpTo(ex, nd); // no exceptional conditions are reported
            fd = 0;
            while (fd < nd) : (fd += 1) {
                if (got_r[fd]) fdSet(rd, fd);
                if (got_w[fd]) fdSet(wr, fd);
            }
            return ready;
        }
        if (kern_signal.interrupted(p)) return sys.signed(-errno.EINTR);
        kern_sched.sleep(arch.clock.pollChannel());
    }
}

fn ticksFrom(sec: i64, sub: i64, sub_per_sec: u64) u64 {
    const hz: u64 = arch.clock.HZ;
    return arch.clock.tickCount() + @as(u64, @intCast(@max(sec, 0))) * hz +
        (@as(u64, @intCast(@max(sub, 0))) * hz + sub_per_sec - 1) / sub_per_sec;
}

/// select(2): `select(nd, readfds, writefds, exceptfds, timeval *timeout)`.
pub fn sysSelect(args: [sys.MAXARGS]u64) u64 {
    var until: ?u64 = null;
    if (args[4] != 0) {
        const tv: *align(1) const kern_time.Timeval = @ptrFromInt(args[4]);
        until = ticksFrom(tv.tv_sec, tv.tv_usec, 1_000_000);
    }
    return selectCommon(args[0], args[1], args[2], args[3], until);
}

/// pselect(2): select with a timespec and a signal mask held for the wait.
pub fn sysPselect(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    var until: ?u64 = null;
    if (args[4] != 0) {
        const ts: *align(1) const kern_time.Timespec = @ptrFromInt(args[4]);
        until = ticksFrom(ts.tv_sec, ts.tv_nsec, 1_000_000_000);
    }
    const saved: u64 = p.sig_mask;
    if (args[5] != 0) p.sig_mask = @as(*align(1) const u64, @ptrFromInt(args[5])).*;
    const r: u64 = selectCommon(args[0], args[1], args[2], args[3], until);
    p.sig_mask = saved;
    return r;
}
