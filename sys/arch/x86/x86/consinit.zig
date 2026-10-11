// SPDX-License-Identifier: GPL-2.0-only
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

/// The conventional first serial port, COM1.
const com1: com.Port = .{
    .tag = bus.BUS_SPACE_IO,
    .iobase = 0x3f8,
};

/// Bring up the early consoles: COM1 always, plus a raster console when the
/// bootloader provided a framebuffer. Both receive kernel output.
pub fn consinit(framebuffer: ?rasops.Raster) void {
    com.init(com1);
    cons.cn_attach(com.console());

    if (framebuffer) |raster| {
        rcons.attach(raster);
        cons.cn_attach(rcons.console());
    }
}
