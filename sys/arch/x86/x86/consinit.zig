// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent console initialisation for the x86 family.
//
// This is the Zig counterpart of sys/arch/x86/x86/consinit.c in NetBSD: it
// selects and attaches the machine's initial console device, shared by every
// x86 port. Machine-independent code (kern/init_main.zig) reaches it only
// through the arch dispatch, so it never names a driver directly.
//
// The choice of physical port belongs here, not in the MI driver: the driver
// knows how to talk to an NS16550, not which one the machine wires to the
// console.

const bus: type = @import("../../../sys/bus.zig");
const com: type = @import("../../../dev/ic/com.zig");
const cons: type = @import("../../../dev/cons.zig");

/// The conventional first serial port, COM1.
const com1: com.Port = .{
    .tag = bus.BUS_SPACE_IO,
    .iobase = 0x3f8,
};

/// Bring up the early console: attach COM1 and install it as the console.
pub fn consinit() void {
    com.init(com1);
    cons.cn_set_tab(com.console());
}
