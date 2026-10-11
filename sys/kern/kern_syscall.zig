// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// System call dispatch.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_syscall.c: it validates
// a system call number and calls the matching handler from the table. The
// machine-dependent entry (x86/x86/syscall.zig) fills in the arguments.

const syscalls: type = @import("syscalls.zig");
const sys: type = @import("../sys/syscall.zig");

/// Dispatch `number` with `args`, returning the value to place in the result
/// register.
pub fn syscall(number: u64, args: [sys.MAXARGS]u64) u64 {
    if (number >= syscalls.table.len) {
        return sys.ERROR;
    }
    const handler = syscalls.table[number] orelse return sys.ERROR;
    return handler(args);
}
