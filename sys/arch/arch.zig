// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine-independent architecture dispatch.
//
// Machine-independent kernel code must never import an arch-specific module
// directly. Instead it imports this file and reaches the current port through
// the names exported below (cpu, locore, bus_space, consinit, boot). The switch
// on the target CPU architecture selects the MD manifest at compile time.

const std: type = @import("std");
const builtin: type = @import("builtin");
const Target: type = std.Target;
const cpu_arch: Target.Cpu.Arch = builtin.target.cpu.arch;

const machdep_impl: type = switch (cpu_arch) {
    .x86_64 => @import("amd64/conf/files.zig"),
    else => @compileError("arch: unsupported architecture"),
};

/// Low-level CPU primitives (halt, interrupt flags, ...).
pub const cpu: type = machdep_impl.cpu;

/// Low-level entry point and ring 3 transition.
pub const locore: type = machdep_impl.locore;

/// Descriptor tables (GDT/TSS).
pub const gdt: type = machdep_impl.gdt;

/// Segment selectors (shared x86).
pub const gdt_defs: type = machdep_impl.gdt_defs;

/// Bus space access implementation (backing sys/sys/bus.zig).
pub const bus_space: type = machdep_impl.bus_space;

/// Machine-dependent console initialisation (see kern/init_main.zig).
pub const consinit: type = machdep_impl.consinit;

/// Machine-dependent page map (see sys/vm).
pub const pmap: type = machdep_impl.pmap;

/// Machine-dependent process context and kernel-thread switch.
pub const proc_md: type = machdep_impl.proc_md;
pub const swtch: type = machdep_impl.swtch;

/// Machine-dependent `syscall` instruction entry.
pub const syscall_entry: type = machdep_impl.syscall_entry;

/// Machine-dependent sysarch(2) requests.
pub const sysarch: type = machdep_impl.sysarch;

/// Machine-dependent trap frame layout.
pub const trapframe: type = machdep_impl.trapframe;

/// Machine-dependent trap entry (current frame, return to ring 3).
pub const trap: type = machdep_impl.trap;

/// Interrupt dispatch (legacy PIC).
pub const intr: type = machdep_impl.intr;

/// Legacy PIC (8259) driver.
pub const pic: type = machdep_impl.pic;

/// Interrupt vector definitions.
pub const intrdefs: type = machdep_impl.intrdefs;

/// System clock / periodic timer.
pub const clock: type = machdep_impl.clock;

/// Machine-dependent virtual memory parameters.
pub const vmparam: type = machdep_impl.vmparam;

/// Machine-dependent CPU services (FreeBSD's <machine/cpu.h>), such as
/// get_cyclecount().
pub const machine_cpu: type = machdep_impl.machine_cpu;

/// Machine parameters (FreeBSD's <machine/param.h>): MACHINE, MACHINE_ARCH.
pub const machine_param: type = machdep_impl.machine_param;

/// User FPU state: save and restore on context switch.
pub const fpu: type = machdep_impl.fpu;

/// Signal frames, sigreturn and machine contexts.
pub const exec_machdep: type = machdep_impl.exec_machdep;

/// The machine context layout (mcontext_t).
pub const ucontext: type = machdep_impl.ucontext;

/// Boot protocol bindings provided by the port.
pub const boot: type = machdep_impl.boot;

comptime {
    _ = machdep_impl.locore;
}
