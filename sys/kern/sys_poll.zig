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
