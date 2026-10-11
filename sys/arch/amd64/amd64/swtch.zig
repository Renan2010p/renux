// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Kernel thread context switch.
//
// The Zig counterpart of NetBSD's cpu_switchto() in sys/arch/amd64/amd64/
// locore.S. Unlike the stack-based variant, it saves the callee-saved registers
// and the resume address in the Context struct, and restores them on the way
// in, so the kernel stack layout plays no part in the switch.
//
// It must be a naked function: a compiler-generated prologue would disturb the
// stack the values are read from. Arguments are the C ABI registers rdi (old)
// and rsi (new).

const Context: type = @import("../include/proc.zig").Context;

fn swtchNaked() callconv(.naked) void {
    asm volatile (
    // Save the old context.
        \\ movq %%rsp, %%rax
        \\ movq (%%rax), %%rcx
        \\ leaq 8(%%rax), %%rdx
        \\ movq %%rdx, (%%rdi)
        \\ movq %%rcx, 56(%%rdi)
        \\ movq %%rbx, 8(%%rdi)
        \\ movq %%rbp, 16(%%rdi)
        \\ movq %%r12, 24(%%rdi)
        \\ movq %%r13, 32(%%rdi)
        \\ movq %%r14, 40(%%rdi)
        \\ movq %%r15, 48(%%rdi)
        // Load the new context.
        \\ movq (%%rsi), %%rsp
        \\ movq 8(%%rsi), %%rbx
        \\ movq 16(%%rsi), %%rbp
        \\ movq 24(%%rsi), %%r12
        \\ movq 32(%%rsi), %%r13
        \\ movq 40(%%rsi), %%r14
        \\ movq 48(%%rsi), %%r15
        \\ jmp *56(%%rsi)
        ::: .{ .memory = true });
}

/// The context switch, callable as an ordinary two-argument function.
pub const SwtchFn: type = *const fn (old: *Context, new: *const Context) callconv(.c) void;
pub const swtch: SwtchFn = @ptrCast(&swtchNaked);
