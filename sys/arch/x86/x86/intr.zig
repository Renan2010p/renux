// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Interrupt dispatch for the x86 family.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/x86/intr.c, reduced to
// what early bring-up needs: a table of handlers indexed by vector, a way to
// register one, and a dispatch entry that runs the handler and acknowledges the
// interrupt controller. The amd64 trap entry calls dispatch() for PIC vectors.

const pic: type = @import("i8259.zig");
const defs: type = @import("../include/intrdefs.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");

/// An interrupt handler. Runs in interrupt context.
pub const Handler: type = *const fn () void;

var handlers: [256]?Handler = undefined;

/// Disable the local APIC.
///
/// The bootloader may leave the local APIC enabled, which routes the legacy
/// PIC's output away from the CPU. Bring-up drives interrupts through the 8259,
/// so the APIC is turned off here. This will be replaced by a proper APIC/IOAPIC
/// path later.
fn disableLocalApic() void {
    const apic_base_msr: u32 = 0x1b;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (apic_base_msr),
    );
    lo &= ~@as(u32, 1 << 11); // clear the global enable bit
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
          [msr] "{ecx}" (apic_base_msr),
    );
}

/// Initialise the legacy interrupt controller and clear the handler table.
pub fn init() void {
    disableLocalApic();
    for (&handlers) |*slot| {
        slot.* = null;
    }
    pic.init();
}

/// Register `handler` for `vector`.
pub fn register(vector: u64, handler: Handler) void {
    handlers[@intCast(vector)] = handler;
}

/// Run the handler for `vector` and acknowledge the controller.
pub fn dispatch(vector: u64) void {
    const v: u8 = @intCast(vector);
    if (handlers[v]) |handler| {
        handler();
    }
    if (defs.isPicVector(vector)) {
        pic.eoi(v);
    }
}

fn intrInit(_: ?*const anyopaque) callconv(.c) void {
    init();
}

comptime {
    sysinit.SYSINIT("sysinit_intr", sysinit.SI_SUB_INTR, sysinit.SI_ORDER_FIRST, intrInit, null);
}
