// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// poll(2).
//
// This is the Zig counterpart of NetBSD's sys/kern/sys_poll.c, reduced to what
// an interactive program needs: report whether the console has input, and wait
// until it does or the timeout elapses. The timeout is measured with the system
// tick, and poll() sleeps on the clock's poll channel, which every tick wakes
// so the wait can be re-checked.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const cons: type = @import("../dev/cons.zig");
const arch: type = @import("../arch/arch.zig");
const kern_sched: type = @import("kern_sched.zig");

/// Event bits (FreeBSD poll.h).
const POLLIN: i16 = 0x0001;
const POLLOUT: i16 = 0x0004;

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
                // The console is the only descriptor with input to wait for;
                // regular files are always ready.
                if ((events & POLLIN) != 0 and cons.cnInputReady()) {
                    revents |= POLLIN;
                }
                if ((events & POLLOUT) != 0) {
                    revents |= POLLOUT;
                }
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
