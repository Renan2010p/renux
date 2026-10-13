// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Device announcement, in FreeBSD's newbus format.
//
// The Zig counterpart of the printing half of FreeBSD's sys/kern/subr_bus.c
// (bus_print_child_header/footer, device_printf). There is no device tree yet,
// but every driver announces its attachment through here, so the boot log
// reads exactly like a FreeBSD dmesg:
//
//   atkbdc0: <Keyboard controller (i8042)> port 0x60,0x64 on isa0
//   atkbd0: <AT Keyboard> irq 1 on atkbdc0
//
// A driver only names itself, its description and its resources; the format
// lives here, in one place.

const prf: type = @import("subr_prf.zig");

/// An attached device instance (the printable part of FreeBSD's device_t).
pub const Device: type = struct {
    /// Driver name, e.g. "uart".
    name: []const u8,
    /// Unit number, e.g. 0 for uart0.
    unit: u32 = 0,
    /// Human-readable description, printed in angle brackets.
    desc: []const u8,
    /// Parent bus instance, e.g. "isa0" or "atkbdc0".
    parent: []const u8,
};

fn printNameunit(dev: *const Device) void {
    prf.print(dev.name);
    prf.printDec(dev.unit);
}

/// Announce an attached device: `name<unit>: <desc>` followed by the resource
/// list formatted from `res_fmt` (which should begin with a space when not
/// empty), then ` on <parent>`.
pub fn announce(dev: *const Device, comptime res_fmt: []const u8, args: anytype) void {
    printNameunit(dev);
    prf.print(": <");
    prf.print(dev.desc);
    prf.putchar('>');
    prf.printf(res_fmt, args);
    prf.print(" on ");
    prf.printLine(dev.parent);
}

/// Print a message prefixed with the device's name and unit (FreeBSD's
/// device_printf()).
pub fn device_printf(dev: *const Device, comptime fmt: []const u8, args: anytype) void {
    printNameunit(dev);
    prf.print(": ");
    prf.printf(fmt, args);
}
