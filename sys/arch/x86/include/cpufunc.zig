// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine-dependent CPU primitives for the x86 family.
//
// This is the Zig counterpart of sys/arch/x86/include/cpufunc.h in NetBSD:
// control-register access, interrupt flag control, the halt instruction and the
// early CPU bring-up, shared by every x86 port. Machine-independent code
// reaches these only through sys/arch/arch.zig (and locore.zig at entry).

/// Read CR0.
fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[value]"
        : [value] "=r" (-> u64),
    );
}

/// Write CR0, with a compiler memory barrier.
fn writeCr0(value: u64) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Read CR4.
fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
}

/// Write CR4, with a compiler memory barrier.
fn writeCr4(value: u64) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Enable the SSE/SSE2 instruction set.
///
/// Limine (and firmware generally) hands the kernel control with CR4.OSFXSR
/// clear, so any SSE instruction faults with #UD. The compiler is free to emit
/// SSE for structure copies and memcpy, so the kernel must enable it during the
/// very first bring-up. CR0.EM is cleared and CR0.MP set; CR4.OSFXSR and
/// CR4.OSXMMEXCPT are set.
///
/// A full port will additionally manage the FPU/SSE state across context
/// switches; that is not needed until scheduling exists.
fn enableSse() void {
    var cr0: u64 = readCr0();
    cr0 &= ~@as(u64, 1 << 2); // clear EM (no x87 emulation)
    cr0 |= @as(u64, 1 << 1); // set MP (monitor coprocessor)
    writeCr0(cr0);

    var cr4: u64 = readCr4();
    cr4 |= @as(u64, 1 << 9); // OSFXSR: FXSAVE/FXRSTOR and SSE
    cr4 |= @as(u64, 1 << 10); // OSXMMEXCPT: unmasked SIMD exceptions
    writeCr4(cr4);
}

/// Early CPU bring-up, run from the machine-dependent entry point.
pub fn startup() void {
    enableSse();
}

/// Halt the CPU until the next interrupt.
pub fn halt() void {
    asm volatile ("hlt");
}

/// The four result registers of a CPUID leaf.
pub const Cpuid: type = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Execute CPUID for `leaf` with sub-leaf `subleaf` (in ecx).
pub fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

/// Read the time-stamp counter (FreeBSD's rdtsc() in <machine/cpufunc.h>).
pub fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Trigger a breakpoint exception (int3). Used to exercise the IDT.
pub fn breakpoint() void {
    asm volatile ("int3");
}

/// Idle forever.
pub fn idle() noreturn {
    while (true) {
        halt();
    }
}

/// Enable maskable interrupts (sti).
pub fn enable_interrupts() void {
    asm volatile ("sti");
}

/// Disable maskable interrupts (cli).
pub fn disable_interrupts() void {
    asm volatile ("cli");
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

/// IA32_FS_BASE: the base of the FS segment (the thread pointer).
const MSR_FS_BASE: u32 = 0xc000_0100;

/// Set the FS base (used for thread-local storage).
pub fn setFsBase(base: u64) void {
    wrmsr(MSR_FS_BASE, base);
}

/// The current FS base.
pub fn fsBase() u64 {
    return rdmsr(MSR_FS_BASE);
}
