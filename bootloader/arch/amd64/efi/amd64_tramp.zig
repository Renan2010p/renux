// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Entering the kernel on amd64.
//
// The counterpart of FreeBSD's stand/efi/loader/arch/amd64/amd64_tramp.S:
// once the firmware is gone, switch to the kernel's stack and page tables
// and jump to its entry point.

/// The stack pointer to enter the kernel with, for a stack whose highest
/// address is `top`.
///
/// The System V ABI wants RSP ≡ 8 (mod 16) at a function's first instruction,
/// as it is right after a `call` pushed the return address. The kernel is
/// entered with a `jmp`, so the loader sets up that state itself.
pub fn initialStackPointer(top: u64) u64 {
    return (top & ~@as(u64, 0xf)) - 8;
}

/// Load `stack` into RSP and `cr3` into CR3, then jump to `entry`.
///
/// The code doing this runs on the identity map, which the new page tables
/// also contain, so it keeps running across the CR3 switch. Never returns.
pub fn enterKernel(entry: u64, cr3: u64, stack: u64) noreturn {
    asm volatile (
        \\ mov %[sp], %%rsp
        \\ mov %[cr3], %%cr3
        \\ jmp *%[entry]
        :
        : [sp] "r" (stack),
          [cr3] "r" (cr3),
          [entry] "r" (entry),
        : .{ .memory = true });
    unreachable;
}
