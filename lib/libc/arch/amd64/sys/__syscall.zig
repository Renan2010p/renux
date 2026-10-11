// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// x86-64 system call primitive.
//
// The Zig counterpart of NetBSD's lib/libc/arch/x86_64/sys/__syscall.S. The
// system call ABI used here is: call number in rax, arguments in rdi, rsi, rdx,
// r10, r8 and r9, result in rax.

pub fn syscall(
    number: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (number),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
          [a3] "{r10}" (a3),
          [a4] "{r8}" (a4),
          [a5] "{r9}" (a5),
        : .{ .memory = true }
    );
}
