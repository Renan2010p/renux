// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine-dependent console initialisation for the x86 family.
//
// This is the Zig counterpart of sys/arch/x86/x86/consinit.c in NetBSD: it
// selects and attaches the machine's initial console devices, shared by every
// x86 port. Machine-independent code (kern/init_main.zig) reaches it only
// through the arch dispatch, so it never names a driver directly.
//
// The choice of physical port belongs here, not in the MI driver: the driver
// knows how to talk to an NS16550, not which one the machine wires to the
// console. Likewise the framebuffer is described by a machine-independent
// raster, built by the caller from the boot-protocol data.

const bus: type = @import("../../../sys/bus.zig");
const com: type = @import("../../../dev/ic/com.zig");
const cons: type = @import("../../../dev/cons.zig");
const rasops: type = @import("../../../dev/rasops/rasops.zig");
const rcons: type = @import("../../../dev/wscons/wscons_raster.zig");
const wsemul: type = @import("../../../dev/wscons/wsemul_vt100.zig");
const subr_bus: type = @import("../../../kern/subr_bus.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");

const uart_dev: subr_bus.Device = .{
    .name = "uart",
    .desc = "16550 or compatible",
    .parent = "isa0",
};

/// The conventional first serial port, COM1.
const com1: com.Port = .{
    .tag = bus.BUS_SPACE_IO,
    .iobase = 0x3f8,
};

/// Whether COM1 was attached as a console, for the uart0 announcement.
var serial_console: bool = false;

/// Bring up the early consoles: COM1 when `serial` is set, and a raster
/// console on `framebuffer` when there is one. Both receive kernel output.
/// The UART is always initialised, so it can be attached later.
pub fn consinit(framebuffer: ?rasops.Raster, serial: bool) void {
    com.init(com1);
    if (serial) {
        cons.cn_attach(com.console());
        serial_console = true;
    }

    // A framebuffer in a pixel format rasops cannot draw (8-bit palette
    // modes) is left alone; the serial console still works.
    if (framebuffer) |raster| {
        if (rcons.attach(raster)) {
            wsemul.init();
            cons.cn_attach(wsemul.console());
        }
    }
    // Never boot without a console: fall back to the serial port.
    if (!cons.cn_attached()) {
        cons.cn_attach(com.console());
        serial_console = true;
    }
}

/// Announce the UART with the ISA devices. "flags 0x10" marks the console,
/// as in FreeBSD's uart(4).
fn uartAttach(_: ?*const anyopaque) callconv(.c) void {
    if (serial_console) {
        subr_bus.announce(&uart_dev, " port 0x3f8-0x3ff irq 4 flags 0x10", .{});
    } else {
        subr_bus.announce(&uart_dev, " port 0x3f8-0x3ff irq 4", .{});
    }
}

comptime {
    sysinit.SYSINIT("sysinit_uart", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_FOURTH, uartAttach, null);
}
