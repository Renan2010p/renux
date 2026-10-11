// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Resource limits.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_resource.c, reduced to
// getrlimit(2) and setrlimit(2) with fixed, generous limits. FreeBSD userland
// (libthr in particular) reads the stack limit while starting up.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");

/// RLIM_INFINITY as a 64-bit signed value.
pub const RLIM_INFINITY: i64 = 0x7fff_ffff_ffff_ffff;

const RLIMIT_CPU: u64 = 0;
const RLIMIT_FSIZE: u64 = 1;
const RLIMIT_DATA: u64 = 2;
const RLIMIT_STACK: u64 = 3;
const RLIMIT_CORE: u64 = 4;
const RLIMIT_RSS: u64 = 5;
const RLIMIT_MEMLOCK: u64 = 6;
const RLIMIT_NPROC: u64 = 7;
const RLIMIT_NOFILE: u64 = 8;
const RLIMIT_SBSIZE: u64 = 9;
const RLIMIT_AS: u64 = 10;
const RLIMIT_NPTS: u64 = 11;
const RLIMIT_SWAP: u64 = 12;
const RLIMIT_KQUEUES: u64 = 13;
const RLIMIT_UMTXP: u64 = 14;

fn putI64(p: u64, v: i64) void {
    const q: *align(1) i64 = @ptrFromInt(p);
    q.* = v;
}

/// getrlimit(2): report the soft and hard limit for `resource`.
pub fn sysGetrlimit(args: [sys.MAXARGS]u64) u64 {
    const resource: u64 = args[0];
    const rlp: u64 = args[1];
    if (resource > RLIMIT_UMTXP) {
        return sys.signed(-errno.EINVAL);
    }
    if (rlp == 0) {
        return sys.signed(-errno.EFAULT);
    }

    var cur: i64 = RLIM_INFINITY;
    var max: i64 = RLIM_INFINITY;
    switch (resource) {
        RLIMIT_STACK => {
            // A finite stack limit: libthr places the main thread's guard page
            // relative to it, so RLIM_INFINITY would overflow the address.
            cur = 64 * 1024 * 1024;
            max = 64 * 1024 * 1024;
        },
        RLIMIT_NOFILE => {
            cur = 64;
            max = 64;
        },
        RLIMIT_NPROC => {
            cur = 16;
            max = 16;
        },
        else => {},
    }
    putI64(rlp, cur);
    putI64(rlp + 8, max);
    return 0;
}

/// setrlimit(2): limits are fixed; accept the call and ignore the values.
pub fn sysSetrlimit(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}
