// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent IDT setup for the x86 family.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/x86/idt.c. It owns the
// interrupt descriptor table and knows how to install a gate and load the
// table. The concrete handlers (the vector stubs) are architecture code and are
// supplied by the caller, keeping this file independent of any one x86 port.

const segments: type = @import("../include/segments.zig");
const gdt_defs: type = @import("../include/gdt.zig");

/// Number of architectural interrupt vectors.
pub const IDT_ENTRIES: usize = 256;

const idtr_t: type = packed struct {
    limit: u16,
    base: u64,
};

/// The interrupt descriptor table.
pub var idt: [IDT_ENTRIES]segments.GateDescriptor = undefined;

var idtr: idtr_t = undefined;

/// Install a gate for `vector` pointing at `handler` in the kernel code
/// segment. `ist` selects an interrupt stack table entry (0 = none).
pub fn setgate(vector: u8, handler: u64, ist: u3, gate_type: u4, dpl: u2) void {
    idt[vector] = segments.makeGate(handler, gdt_defs.KCODE_SEL, ist, gate_type, dpl);
}

/// Load the IDT into the CPU.
pub fn load() void {
    idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
        : .{ .memory = true });
}
