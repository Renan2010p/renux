// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// amd64 trap handling.
//
// This plays the role of NetBSD's sys/arch/amd64/amd64/trap.c: the common
// entry saves the machine state, hands a trap frame to the machine-independent
// dispatcher and restores state on the way out. Exceptions that cannot be
// recovered are reported and halt the machine.

const trap: type = @import("../include/trap.zig");
const prf: type = @import("../../../kern/subr_prf.zig");

/// Common entry point for every vector stub (see vector.zig).
///
/// On entry the stack holds, from the top: the vector number, the error code,
/// and the CPU-pushed frame. All general registers are saved to build a
/// TrapFrame, zb_trap_dispatch() is called with a pointer to it, and the state
/// is restored before returning with iretq.
pub export fn trap_common() callconv(.naked) void {
    asm volatile (
        \\ pushq %%rax
        \\ pushq %%rcx
        \\ pushq %%rdx
        \\ pushq %%rbx
        \\ pushq %%rbp
        \\ pushq %%rsi
        \\ pushq %%rdi
        \\ pushq %%r8
        \\ pushq %%r9
        \\ pushq %%r10
        \\ pushq %%r11
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ movq %%rsp, %%rdi
        \\ call zb_trap_dispatch
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%r11
        \\ popq %%r10
        \\ popq %%r9
        \\ popq %%r8
        \\ popq %%rdi
        \\ popq %%rsi
        \\ popq %%rbp
        \\ popq %%rbx
        \\ popq %%rdx
        \\ popq %%rcx
        \\ popq %%rax
        \\ addq $16, %%rsp
        \\ iretq
    );
}

/// Trap dispatcher, called by trap_common().
///
/// Reports the trap on the console. The breakpoint vector is used by the
/// bring-up self-test and resumes execution; every other vector is fatal for
/// now, until per-vector recovery exists.
export fn zb_trap_dispatch(frame: *trap.TrapFrame) callconv(.c) void {
    prf.print("trap: vector ");
    prf.printDec(frame.vector);
    prf.print(" error ");
    prf.printHex(frame.error_code);
    prf.print(" rip ");
    prf.printHex(frame.rip);
    prf.printLine("");

    if (frame.vector == trap.T_BREAKPOINT) {
        return;
    }

    prf.panic("unhandled trap", null);
}
