// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Kernel thread context switch.
//
// The Zig counterpart of NetBSD's cpu_switchto() in sys/arch/amd64/amd64/
// locore.S. It pushes the callee-saved registers on the current stack, records
// the stack pointer in `old`, loads `new`'s stack pointer, pops the callee-saved
// registers and returns to where `new` last called swtch() (or to its startup
// trampoline the first time).
//
// It must be a naked function: a compiler-generated prologue would place data
// between the return address and the saved registers, and the final `ret` would
// return to that data instead of the caller. Arguments are taken from the C ABI
// registers rdi (old) and rsi (new).

const Context: type = @import("../include/proc.zig").Context;

fn swtchNaked() callconv(.naked) void {
    asm volatile (
        \\ pushq %%rbx
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ movq %%rsp, (%%rdi)
        \\ movq (%%rsi), %%rsp
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%rbx
        \\ ret
        ::: .{ .memory = true });
}

/// The context switch, callable as an ordinary two-argument function.
pub const SwtchFn: type = *const fn (old: *Context, new: *const Context) callconv(.c) void;
pub const swtch: SwtchFn = @ptrCast(&swtchNaked);
