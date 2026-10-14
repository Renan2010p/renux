// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// 8259 interrupt controller driver.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/x86/i8259.c: it remaps
// the two cascaded 8259 PICs above the CPU exceptions, masks all lines, and
// provides unmask and end-of-interrupt operations. Registers are reached
// through bus_space.

const bus_space: type = @import("bus_space.zig");
const isa: type = @import("../../../dev/isa/isareg.zig");
const pic: type = @import("../include/i8259.zig");
const subr_bus: type = @import("../../../core/subr_bus.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");

const dev: subr_bus.Device = .{
    .name = "atpic",
    .desc = "AT PIC",
    .parent = "isa0",
};

fn outb(port: u16, value: u8) void {
    bus_space.write1(.io, port, 0, value);
}

fn inb(port: u16) u8 {
    return bus_space.read1(.io, port, 0);
}

/// Remap both PICs to vectors 0x20..0x2f and mask every line.
pub fn init() void {
    // Master.
    outb(isa.IO_PIC1, pic.ICW1_INIT | pic.ICW1_ICW4);
    outb(isa.IO_PIC1 + 1, pic.PIC_MASTER_OFFSET);
    outb(isa.IO_PIC1 + 1, @as(u8, 1) << pic.PIC_CASCADE_IRQ);
    outb(isa.IO_PIC1 + 1, pic.ICW4_8086);

    // Slave.
    outb(isa.IO_PIC2, pic.ICW1_INIT | pic.ICW1_ICW4);
    outb(isa.IO_PIC2 + 1, pic.PIC_SLAVE_OFFSET);
    outb(isa.IO_PIC2 + 1, pic.PIC_CASCADE_IRQ);
    outb(isa.IO_PIC2 + 1, pic.ICW4_8086);

    // Mask all interrupts.
    outb(isa.IO_PIC1 + 1, 0xff);
    outb(isa.IO_PIC2 + 1, 0xff);
}

/// Unmask the given IRQ line (0..15).
pub fn enableIrq(irq: u3) void {
    if (irq < 8) {
        outb(isa.IO_PIC1 + 1, inb(isa.IO_PIC1 + 1) & ~(@as(u8, 1) << irq));
    } else {
        outb(isa.IO_PIC2 + 1, inb(isa.IO_PIC2 + 1) & ~(@as(u8, 1) << (irq - 8)));
        // The slave is reached through the master's cascade line.
        outb(isa.IO_PIC1 + 1, inb(isa.IO_PIC1 + 1) & ~(@as(u8, 1) << pic.PIC_CASCADE_IRQ));
    }
}

/// Mask the given IRQ line (0..15).
pub fn disableIrq(irq: u3) void {
    if (irq < 8) {
        outb(isa.IO_PIC1 + 1, inb(isa.IO_PIC1 + 1) | (@as(u8, 1) << irq));
    } else {
        outb(isa.IO_PIC2 + 1, inb(isa.IO_PIC2 + 1) | (@as(u8, 1) << (irq - 8)));
    }
}

/// Signal end-of-interrupt for the vector that was just handled.
pub fn eoi(vector: u8) void {
    const irq: u8 = vector - pic.PIC_MASTER_OFFSET;
    if (irq >= 8) {
        outb(isa.IO_PIC2, pic.OCW2_EOI);
    }
    outb(isa.IO_PIC1, pic.OCW2_EOI);
}

/// Announce the controller once devices are configured. It was programmed
/// much earlier, at SI_SUB_INTR; like FreeBSD's atpic it only shows up in the
/// device list when the ISA devices attach.
fn atpicAttach(_: ?*const anyopaque) callconv(.c) void {
    subr_bus.announce(&dev, " port 0x20-0x21,0xa0-0xa1", .{});
}

comptime {
    sysinit.SYSINIT("sysinit_atpic", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_FIRST, atpicAttach, null);
}
