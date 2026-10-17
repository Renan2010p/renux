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
const arch_vmparam: type = @import("../include/vmparam.zig");
const vm_page: type = @import("../../../vm/vm_page.zig");
const sys: type = @import("../../../sys/syscall.zig");
const errno: type = @import("../../../sys/errno.zig");
const kern_sched: type = @import("../../../core/kern_sched.zig");
const kern_signal: type = @import("../../../core/kern_signal.zig");
const kern_exit: type = @import("../../../core/kern_exit.zig");
const kern_proc: type = @import("../../../core/kern_proc.zig");
const param: type = @import("../../../sys/param.zig");
const signal: type = @import("../../../sys/signal.zig");
const prf: type = @import("../../../core/subr_prf.zig");

/// Synthetic vector the `syscall` entry pushes so the dispatcher can apply the
/// FreeBSD error convention (carry flag + errno).
pub const FASTSYSCALL_VECTOR: u64 = 0x81;

/// The result a handler gives when it loaded the frame itself.
const JUSTRETURN: u64 = sys.signed(-errno.EJUSTRETURN);

/// True when the trap being handled interrupted user mode: the clock
/// charges its tick as user time then, system time otherwise.
pub var intr_from_user: bool = false;

/// The frame the running thread entered the kernel from user mode with (for
/// fork, sigreturn, getcontext, thr_new, ...). Each thread keeps its own, so
/// a thread that sleeps in a system call still finds its frame after other
/// threads have trapped.
pub fn currentFrame() ?*trap.TrapFrame {
    return kern_proc.curthread.trapframe;
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

/// Page-fault error code bits.
const PF_PRESENT: u64 = 1 << 0; // the page was present (a protection fault)
const PF_WRITE: u64 = 1 << 1; // the access was a write
const PF_USER: u64 = 1 << 2; // the access came from user mode

/// Resolve a page fault on a user address from the current process's map
/// (vm/vm_fault.zig): a page not made yet, or a write to a copy-on-write
/// page. Returns false when the access is not allowed.
fn handlePageFault(frame: *trap.TrapFrame) bool {
    const va: u64 = readCr2();
    if (va >= arch_vmparam.VM_MAXUSER_ADDRESS) return false;
    const p = kern_proc.current;
    return vm_fault.fault(kern_proc.vmOf(p), p.pmap, va, (frame.error_code & PF_WRITE) != 0);
}

/// Trap dispatcher, called by trap_common().
export fn zb_trap_dispatch(frame: *trap.TrapFrame) callconv(.c) void {
    dispatchTrap(frame);

    // Deliver a pending signal when control is about to return to user mode.
    if (frame.cs == gdt_defs.UCODE_SEL) {
        // A thread whose sibling is ending the process (or exec'ing) leaves
        // here instead of returning to user mode.
        kern_exit.checkSingleThread();
        kern_signal.deliver(frame);
    }
}

/// Handle the trap, possibly adjusting `frame` on the way out.
fn dispatchTrap(frame: *trap.TrapFrame) void {
    // Only a trap from user mode carries the user registers; an interrupt
    // taken in the kernel must not replace them.
    if (frame.cs == gdt_defs.UCODE_SEL) kern_proc.curthread.trapframe = frame;
    intr_from_user = frame.cs == gdt_defs.UCODE_SEL;

    if (frame.vector == vector.SYSCALL_VECTOR) {
        const result: u64 = syscall.dispatch(
            frame.rax,
            frame.rdi,
            frame.rsi,
            frame.rdx,
            frame.r10,
            frame.r8,
            frame.r9,
        );
        if (result != JUSTRETURN) frame.rax = result;
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
        // sigreturn and setcontext have loaded the whole frame already.
        if (result == JUSTRETURN) return;
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
        // A bad user address -- touched by the program, or by the kernel on
        // its behalf (a system call given a bad pointer) -- costs the
        // process SIGSEGV; only a fault on a kernel address is the kernel's.
        if ((frame.error_code & PF_USER) != 0 or readCr2() < arch_vmparam.VM_MAXUSER_ADDRESS) {
            kern_exit.exitSignal(signal.SIGSEGV);
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
        kern_exit.exitSignal(signal.SIGSEGV);
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
