// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Process credentials.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_prot.c, reduced to
// getuid(2) and setuid(2). There is no user database yet, so setuid is
// unprivileged and simply records the requested id.

const sys: type = @import("../sys/syscall.zig");
const kern_proc: type = @import("kern_proc.zig");

/// getuid(2): the real user id.
pub fn sysGetuid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.uid);
}

/// setuid(2): set the (single) user id.
pub fn sysSetuid(args: [sys.MAXARGS]u64) u64 {
    kern_proc.current.uid = @truncate(args[0]);
    return 0;
}
