// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// x86 system call entry glue.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/x86/syscall.c, limited
// to the legacy int 0x80 path. The x86 system call ABI used here is: the call
// number in rax, arguments in rdi, rsi, rdx, r10, r8 and r9, and the result in
// rax. The machine-dependent trap entry extracts those registers from the trap
// frame and calls dispatch().

const kern_syscall: type = @import("../../../kern/kern_syscall.zig");
const sys: type = @import("../../../sys/syscall.zig");

/// Dispatch a system call given its raw register arguments.
pub fn dispatch(
    number: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
) u64 {
    const args: [sys.MAXARGS]u64 = .{ a0, a1, a2, a3, a4, a5 };
    return kern_syscall.syscall(number, args);
}
