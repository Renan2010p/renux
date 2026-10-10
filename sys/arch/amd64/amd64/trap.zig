// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// amd64 trap handling.
//
// This plays the role of NetBSD's sys/arch/amd64/amd64/trap.c: the common
// entry saves the machine state, hands a trap frame to the machine-independent
// dispatcher and restores state on the way out. Page faults are offered to the
// fault registry, PIC vectors are handed to the interrupt dispatcher, and
// anything that cannot be recovered is reported and halts the machine.

const trap: type = @import("../include/trap.zig");
const intr: type = @import("../../x86/x86/intr.zig");
const intrdefs: type = @import("../../x86/include/intrdefs.zig");
const pmap: type = @import("../../x86/x86/pmap.zig");
const uvm_fault: type = @import("../../../uvm/uvm_fault.zig");
const uvm_page: type = @import("../../../uvm/uvm_page.zig");
const param: type = @import("../../../sys/param.zig");
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

/// Read CR2, the address that caused the most recent page fault.
fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[value]"
        : [value] "=r" (-> u64),
    );
}

/// Try to resolve a not-present page fault by mapping a demand-zero page.
fn handlePageFault(frame: *trap.TrapFrame) bool {
    if ((frame.error_code & 1) != 0) {
        return false; // protection fault, not a missing page
    }
    const va: u64 = readCr2();
    if (uvm_fault.regionFor(va) == null) {
        return false;
    }
    const pa: u64 = uvm_page.physalloc() orelse return false;
    pmap.kenterPa(va & ~param.PAGE_MASK, pa, .kernel_rw);
    return true;
}

/// Trap dispatcher, called by trap_common().
export fn zb_trap_dispatch(frame: *trap.TrapFrame) callconv(.c) void {
    if (frame.vector == trap.T_PAGE) {
        if (handlePageFault(frame)) {
            return;
        }
        prf.print("page fault at ");
        prf.printHex(readCr2());
        prf.print(" error ");
        prf.printHex(frame.error_code);
        prf.printLine("");
        prf.panic("unhandled page fault", null);
    }

    if (intrdefs.isPicVector(frame.vector)) {
        intr.dispatch(frame.vector);
        return;
    }

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
