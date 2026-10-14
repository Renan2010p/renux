// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// x86-64 fast system call entry.
//
// This is the Zig counterpart of the `syscall` entry in FreeBSD's
// sys/amd64/amd64/exception.S (its LSTAR target). The `syscall` instruction
// leaves the user stack in place, so the entry first switches to the current
// process's kernel stack (kept in zb_syscall_kstack), then builds the same trap
// frame the interrupt path uses and calls the common dispatcher. It returns
// with iretq, so signal delivery and the rest of the trap machinery work
// unchanged. Errors follow the FreeBSD convention (carry flag set, errno in
// rax), handled by the dispatcher for the fast vector.

const std: type = @import("std");
const specialreg: type = @import("../../x86/include/specialreg.zig");
const gdt_defs: type = @import("../../x86/include/gdt.zig");

// The user selectors, spelled into the assembly from the GDT definitions.
const UCODE: []const u8 = std.fmt.comptimePrint("{d}", .{gdt_defs.UCODE_SEL});
const UDATA: []const u8 = std.fmt.comptimePrint("{d}", .{gdt_defs.UDATA_SEL});
const sysinit: type = @import("../../../sys/sysinit.zig");

/// Kernel stack top of the process about to run in user mode. Updated by the
/// scheduler on every switch.
export var zb_syscall_kstack: u64 = 0;

/// Scratch slot holding the user stack pointer saved on entry.
export var zb_syscall_ustack: u64 = 0;

/// The LSTAR entry point. Builds a trap frame:
///   r15..rax (lowest), vector, error, rip, cs, rflags, rsp, ss (highest)
/// then dispatches. The common case returns with sysretq, as FreeBSD's fast
/// path does: when the call returns to where it came from (rip still equals
/// the rcx the syscall instruction saved), with the standard user selectors
/// and a canonical address. rcx and r11 come back as rip and rflags, which
/// the syscall instruction clobbers anyway, so the program sees no
/// difference. Anything else (a signal handler, execve, sigreturn) returns
/// with iretq, which restores every register.
pub export fn zb_syscall_entry() callconv(.naked) void {
    asm volatile (
        \\ movq %rsp, zb_syscall_ustack(%rip)
        \\ movq zb_syscall_kstack(%rip), %rsp
    ++ "\n" ++ " pushq $" ++ UDATA ++ "\n" ++
        \\ pushq zb_syscall_ustack(%rip)
        \\ pushq %r11
    ++ "\n" ++ " pushq $" ++ UCODE ++ "\n" ++
        \\ pushq %rcx
        \\ pushq $0
        \\ pushq $0x81
        \\ pushq %rax
        \\ pushq %rcx
        \\ pushq %rdx
        \\ pushq %rbx
        \\ pushq %rbp
        \\ pushq %rsi
        \\ pushq %rdi
        \\ pushq %r8
        \\ pushq %r9
        \\ pushq %r10
        \\ pushq %r11
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq %r14
        \\ pushq %r15
        \\ movq %rsp, %rdi
        \\ call zb_trap_dispatch
        \\ cli
        \\ movq 104(%rsp), %rcx
        \\ cmpq 136(%rsp), %rcx
        \\ jne 1f
    ++ "\n" ++ " cmpq $" ++ UCODE ++ ", 144(%rsp)" ++ "\n" ++
        \\ jne 1f
    ++ "\n" ++ " cmpq $" ++ UDATA ++ ", 168(%rsp)" ++ "\n" ++
        \\ jne 1f
        \\ movabsq $0x00007ffffffff000, %r11
        \\ cmpq %r11, %rcx
        \\ jae 1f
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ addq $8, %rsp
        \\ popq %r10
        \\ popq %r9
        \\ popq %r8
        \\ popq %rdi
        \\ popq %rsi
        \\ popq %rbp
        \\ popq %rbx
        \\ popq %rdx
        \\ addq $8, %rsp
        \\ popq %rax
        \\ movq 16(%rsp), %rcx
        \\ movq 32(%rsp), %r11
        \\ movq 40(%rsp), %rsp
        \\ sysretq
        \\1:
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ popq %r11
        \\ popq %r10
        \\ popq %r9
        \\ popq %r8
        \\ popq %rdi
        \\ popq %rsi
        \\ popq %rbp
        \\ popq %rbx
        \\ popq %rdx
        \\ popq %rcx
        \\ popq %rax
        \\ addq $16, %rsp
        \\ iretq
    );
}

/// Record the kernel stack the entry should switch to.
pub fn setKernelStack(top: u64) void {
    zb_syscall_kstack = top;
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn wrmsr(msr: u32, value: u64) void {
    const lo: u32 = @truncate(value);
    const hi: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
          [msr] "{ecx}" (msr),
    );
}

/// Enable and point the `syscall` instruction at the entry.
pub fn init() void {
    // Enable syscall/sysret.
    wrmsr(specialreg.MSR_EFER, rdmsr(specialreg.MSR_EFER) | specialreg.EFER_SCE);

    // syscall: CS = 0x08 (kernel code), SS = 0x10 (kernel data).
    // sysretq: SS = 0x10 + 8 = 0x18 | 3 (user data, 0x1b) and
    // CS = 0x10 + 16 = 0x20 | 3 (user code, 0x23).
    wrmsr(specialreg.MSR_STAR, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));

    wrmsr(specialreg.MSR_LSTAR, @intFromPtr(&zb_syscall_entry));

    // Clear IF on entry so the kernel stack switch is not interrupted.
    wrmsr(specialreg.MSR_SFMASK, 0x200);
}

fn entryInit(_: ?*const anyopaque) callconv(.c) void {
    init();
}

comptime {
    sysinit.SYSINIT("sysinit_syscall", sysinit.SI_SUB_INTR, sysinit.SI_ORDER_MIDDLE, entryInit, null);
}
