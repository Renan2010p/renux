// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 kernel entry trampoline.
//
// The counterpart of FreeBSD's stand/efi/loader/arch/amd64/amd64_tramp.S:
// once the firmware is gone, switch to the kernel's stack and page tables
// and jump to its entry point.

/// Enter the kernel at `entry` with CR3 set to `cr3` and the stack at
/// `stack`. Never returns.
pub fn tramp(entry: u64, cr3: u64, stack: u64) noreturn {
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
