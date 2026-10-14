// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 trap handling.
//
// This plays the role of NetBSD's sys/arch/amd64/amd64/trap.c: the common
// entry saves the machine state, hands a trap frame to the machine-independent
// dispatcher and restores state on the way out. Page faults are offered to the
// fault registry, PIC vectors are handed to the interrupt dispatcher, and
// anything that cannot be recovered is reported and halts the machine.

const trap: type = @import("../include/trap.zig");
const gdt_defs: type = @import("../../x86/include/gdt.zig");
const intr: type = @import("../../x86/x86/intr.zig");
const intrdefs: type = @import("../../x86/include/intrdefs.zig");
const pmap: type = @import("../../x86/x86/pmap.zig");
const syscall: type = @import("../../x86/x86/syscall.zig");
const vector: type = @import("vector.zig");
const vm_fault: type = @import("../../../vm/vm_fault.zig");
const vm_page: type = @import("../../../vm/vm_page.zig");
const sys: type = @import("../../../sys/syscall.zig");
const errno: type = @import("../../../sys/errno.zig");
const kern_sched: type = @import("../../../kern/kern_sched.zig");
const kern_signal: type = @import("../../../kern/kern_signal.zig");
const kern_exit: type = @import("../../../kern/kern_exit.zig");
const kern_proc: type = @import("../../../kern/kern_proc.zig");
const param: type = @import("../../../sys/param.zig");
const prf: type = @import("../../../kern/subr_prf.zig");

/// The trap frame of the trap currently being handled (used by fork()).
var trap_frame: ?*trap.TrapFrame = null;

/// Synthetic vector the `syscall` entry pushes so the dispatcher can apply the
/// FreeBSD error convention (carry flag + errno).
pub const FASTSYSCALL_VECTOR: u64 = 0x81;

/// The trap frame being handled on this CPU, if any.
pub fn currentFrame() ?*trap.TrapFrame {
    return trap_frame;
}

/// Common entry point for every vector stub (see vector.zig).
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
    const r = vm_fault.regionFor(kern_proc.current, va) orelse return false;
    const prot: pmap.Prot = if (r.exec) .user_rx else if (r.write) .user_rw else .user_ro;
    // allocPage records the page in the address space, so it is freed with it.
    const pa: u64 = pmap.allocPage(pmap.current()) orelse return false;
    pmap.enterUser(pmap.current(), va & ~param.PAGE_MASK, pa, prot);
    return true;
}

/// Trap dispatcher, called by trap_common().
export fn zb_trap_dispatch(frame: *trap.TrapFrame) callconv(.c) void {
    dispatchTrap(frame);

    // Deliver a pending signal when control is about to return to user mode.
    if (frame.cs == gdt_defs.UCODE_SEL) {
        kern_signal.deliver(frame);
    }
}

/// Handle the trap, possibly adjusting `frame` on the way out.
fn dispatchTrap(frame: *trap.TrapFrame) void {
    trap_frame = frame;

    if (frame.vector == vector.SYSCALL_VECTOR) {
        frame.rax = syscall.dispatch(
            frame.rax,
            frame.rdi,
            frame.rsi,
            frame.rdx,
            frame.r10,
            frame.r8,
            frame.r9,
        );
        return;
    }

    if (frame.vector == FASTSYSCALL_VECTOR) {
        // FreeBSD convention: on error, set the carry flag and put the errno in
        // rax; on success clear the carry flag.
        const result: u64 = syscall.dispatch(
            frame.rax,
            frame.rdi,
            frame.rsi,
            frame.rdx,
            frame.r10,
            frame.r8,
            frame.r9,
        );
        if (result == sys.ERROR) {
            frame.rax = @intCast(errno.EINVAL);
            frame.rflags |= 1;
        } else {
            const signed_result: i64 = @bitCast(result);
            if (signed_result < 0) {
                // The handler returned a negative errno.
                frame.rax = @intCast(-signed_result);
                frame.rflags |= 1;
            } else {
                frame.rax = result;
                frame.rflags &= ~@as(u64, 1);
            }
        }
        return;
    }

    if (frame.vector == trap.T_PAGE) {
        if (handlePageFault(frame)) {
            return;
        }
        prf.log(prf.LOG_ERR, "pid %d (%s): page fault at %x error %x rip %x", .{ kern_proc.current.pid, kern_proc.current.name[0..kern_proc.current.name_len], readCr2(), frame.error_code, frame.rip });
        // The translation path, so a malformed entry (error bit 3, RSVD) or a
        // missing level shows at once.
        const e = pmap.walk(kern_proc.current.pmap, readCr2());
        prf.log(prf.LOG_ERR, "  pml4e %x pdpte %x pde %x pte %x", .{ e[0], e[1], e[2], e[3] });
        // A fault from user mode kills the process (as SIGSEGV); only a kernel
        // fault panics.
        if ((frame.error_code & 0x4) != 0) {
            kern_exit.exit(139); // 128 + SIGSEGV
        }
        prf.panic("unhandled page fault", null);
    }

    if (intrdefs.isPicVector(frame.vector)) {
        intr.dispatch(frame.vector);
        // Preempt the running process on device interrupts.
        if (!kern_sched.in_scheduler) {
            kern_sched.yield();
        }
        return;
    }

    prf.log(prf.LOG_ERR, "trap: vector %d error %x rip %x", .{ frame.vector, frame.error_code, frame.rip });

    if (frame.vector == trap.T_BREAKPOINT) {
        return;
    }

    // An unhandled trap from user mode kills the process; a kernel trap panics.
    if ((frame.cs & 0x3) == 0x3) {
        kern_exit.exit(139); // 128 + SIGSEGV
    }

    prf.panic("unhandled trap", null);
}

/// Return to ring 3 using `frame`, which lives in a process's Proc (not on the
/// kernel stack). Used the first time a freshly created process runs, where
/// there is no interrupt frame to return from.
pub fn usertrapret(frame: *const trap.TrapFrame) noreturn {
    asm volatile (
        \\ movq %[f], %%r11
        \\ pushq 168(%%r11)
        \\ pushq 160(%%r11)
        \\ pushq 152(%%r11)
        \\ pushq 144(%%r11)
        \\ pushq 136(%%r11)
        \\ movq 112(%%r11), %%rax
        \\ movq 104(%%r11), %%rcx
        \\ movq 96(%%r11), %%rdx
        \\ movq 88(%%r11), %%rbx
        \\ movq 80(%%r11), %%rbp
        \\ movq 72(%%r11), %%rsi
        \\ movq 64(%%r11), %%rdi
        \\ movq 56(%%r11), %%r8
        \\ movq 48(%%r11), %%r9
        \\ movq 40(%%r11), %%r10
        \\ movq 24(%%r11), %%r12
        \\ movq 16(%%r11), %%r13
        \\ movq 8(%%r11), %%r14
        \\ movq 0(%%r11), %%r15
        \\ movq 32(%%r11), %%r11
        \\ iretq
        :
        : [f] "r" (frame),
        : .{ .memory = true });
    unreachable;
}
