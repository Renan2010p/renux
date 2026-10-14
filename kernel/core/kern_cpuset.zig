// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// CPU sets.
//
// The Zig counterpart of the query half of FreeBSD's sys/kern/kern_cpuset.c.
// Renux runs on one CPU, so every set is {0}. FreeBSD's libc asks for it at
// startup (jemalloc sizes its arenas by the CPUs a process may use).

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");

/// cpuset_getaffinity(2): `cpuset_getaffinity(level, which, id, setsize,
/// mask)`. Fills `mask` (a cpuset_t of `setsize` bytes) with CPU 0 only.
pub fn sysCpusetGetaffinity(args: [sys.MAXARGS]u64) u64 {
    const setsize: u64 = args[3];
    const mask_ptr: u64 = args[4];
    if (setsize == 0 or setsize > 1024 or mask_ptr == 0) {
        return sys.signed(-errno.ERANGE);
    }
    const mask: [*]u8 = @ptrFromInt(mask_ptr);
    @memset(mask[0..@intCast(setsize)], 0);
    mask[0] = 1; // CPU 0
    return 0;
}
