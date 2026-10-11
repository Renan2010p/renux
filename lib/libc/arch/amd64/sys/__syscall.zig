// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// x86-64 system call primitive.
//
// The Zig counterpart of FreeBSD's lib/libc/amd64/SYS.h / NetBSD's
// lib/libc/arch/x86_64/sys/__syscall.S. ZenBSD follows the FreeBSD ABI: the
// call is made with the `syscall` instruction, number in rax and arguments in
// rdi, rsi, rdx, r10, r8 and r9. On error the kernel sets the carry flag and
// returns the errno in rax; this wrapper turns that into the negative errno the
// rest of the library expects.

pub fn syscall(
    number: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
) u64 {
    var ret: u64 = undefined;
    var carry: u8 = undefined;
    asm volatile (
        \\ syscall
        \\ setc %[cf]
        : [ret] "={rax}" (ret),
          [cf] "=r" (carry),
        : [nr] "{rax}" (number),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
          [a3] "{r10}" (a3),
          [a4] "{r8}" (a4),
          [a5] "{r9}" (a5),
        : .{ .rcx = true, .r11 = true, .memory = true });
    if (carry != 0) {
        return @bitCast(-@as(i64, @intCast(ret)));
    }
    return ret;
}
