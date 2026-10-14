// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// getrandom(2).
//
// The counterpart of FreeBSD's sys/kern/sys_getrandom.c: fill a user buffer
// from the kernel generator (dev/random/randomdev.zig).

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const randomdev: type = @import("../dev/random/randomdev.zig");

/// getrandom(2): `getrandom(buf, buflen, flags)`. The generator never
/// blocks, so GRND_NONBLOCK and GRND_RANDOM change nothing.
pub fn sysGetrandom(args: [sys.MAXARGS]u64) u64 {
    const GRND_NONBLOCK: u64 = 0x1;
    const GRND_RANDOM: u64 = 0x2;
    const GRND_INSECURE: u64 = 0x4;
    if ((args[2] & ~(GRND_NONBLOCK | GRND_RANDOM | GRND_INSECURE)) != 0) return sys.signed(-errno.EINVAL);
    // Bound one request to a sane size, like FreeBSD's IOSIZE_MAX check.
    const len: usize = @intCast(@min(args[1], 1 << 20));
    const dst: [*]u8 = @ptrFromInt(args[0]);
    randomdev.read_random(dst[0..len]);
    return len;
}
