// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// EHCI USB 2.0 controllers: take them from the firmware and stop them.
//
// The Zig counterpart of ehci_pci_takecontroller() in FreeBSD's
// sys/dev/usb/controller/ehci_pci.c. There is no EHCI driver yet; on the PCs
// that have both kinds of controller (Intel 7, 8 and 9 Series) the xHCI
// driver routes every port to itself. But the firmware's "legacy USB"
// support keeps running on the EHCI controllers through SMIs until the
// operating system claims them, and may still be scheduling DMA, so each
// one is claimed through its USB Legacy Support capability, its SMIs are
// turned off and it is halted.

const arch: type = @import("../../../arch/arch.zig");
const bus: type = @import("../../../sys/bus.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");
const subr_bus: type = @import("../../../core/subr_bus.zig");
const pci: type = @import("../../pci/pci.zig");

const PCIC_SERIALBUS: u8 = 0x0c;
const PCIS_SERIALBUS_USB: u8 = 0x03;
const PCIP_SERIALBUS_USB_EHCI: u8 = 0x20;

/// Capability registers (ehcireg.h).
const EHCI_CAPLENGTH: u64 = 0x00; // u8, with HCIVERSION above it
const EHCI_HCCPARAMS: u64 = 0x08;
fn EHCI_HCC_EECP(x: u32) u16 {
    return @intCast((x >> 8) & 0xff);
}

/// Operational registers.
const EHCI_USBCMD: u64 = 0x00;
const EHCI_CMD_RS: u32 = 1 << 0;
const EHCI_USBSTS: u64 = 0x04;
const EHCI_STS_HCH: u32 = 1 << 12;
const EHCI_USBINTR: u64 = 0x08;

/// USB Legacy Support extended capability, in PCI configuration space.
const EHCI_EC_LEGSUP: u32 = 0x01;
const EHCI_LEGSUP_BIOS_SEM: u32 = 1 << 16;
const EHCI_LEGSUP_OS_SEM: u32 = 1 << 24;
const EHCI_LEGCTLSTS: u16 = 4;

fn rd4(base: u64, off: u64) u32 {
    return bus.bus_space_read_4(bus.BUS_SPACE_MEM, base, off);
}

fn wr4(base: u64, off: u64, v: u32) void {
    bus.bus_space_write_4(bus.BUS_SPACE_MEM, base, off, v);
}

/// Claim the controller from the BIOS and silence its SMIs. Returns false
/// when the BIOS would not let go.
fn takeController(dev: *const pci.PciDev, cap: u64) bool {
    var released: bool = true;
    var eecp: u16 = EHCI_HCC_EECP(rd4(cap, EHCI_HCCPARAMS));
    var guard: u32 = 0;
    while (eecp >= 0x40 and guard < 16) : (guard += 1) {
        const v: u32 = pci.read_config(dev, eecp, 4);
        if ((v & 0xff) == EHCI_EC_LEGSUP) {
            if ((v & EHCI_LEGSUP_BIOS_SEM) != 0) {
                pci.write_config(dev, eecp, v | EHCI_LEGSUP_OS_SEM, 4);
                var i: u32 = 0;
                while (i < 10_000 and (pci.read_config(dev, eecp, 4) & EHCI_LEGSUP_BIOS_SEM) != 0) : (i += 1) {
                    arch.clock.DELAY(100);
                }
                released = (pci.read_config(dev, eecp, 4) & EHCI_LEGSUP_BIOS_SEM) == 0;
            }
            // SMIs off, and their pending events cleared.
            pci.write_config(dev, eecp + EHCI_LEGCTLSTS, 0, 4);
        }
        eecp = @intCast((v >> 8) & 0xff);
    }
    return released;
}

fn ehciProbe(dev: *const pci.PciDev) ?[]const u8 {
    if (dev.class != PCIC_SERIALBUS or dev.subclass != PCIS_SERIALBUS_USB or dev.progif != PCIP_SERIALBUS_USB_EHCI) return null;
    if (dev.bars[0].io or dev.bars[0].size == 0) return null;
    if (dev.vendor == 0x8086) {
        return switch (dev.device) {
            0x1e26 => "Intel Panther Point USB 2.0 controller USB-A",
            0x1e2d => "Intel Panther Point USB 2.0 controller USB-B",
            0x8c26 => "Intel Lynx Point USB 2.0 controller USB-A",
            0x8c2d => "Intel Lynx Point USB 2.0 controller USB-B",
            0x8ca6 => "Intel Wildcat Point USB 2.0 controller USB-A",
            0x8cad => "Intel Wildcat Point USB 2.0 controller USB-B",
            else => "Intel EHCI USB 2.0 controller",
        };
    }
    return "EHCI (generic) USB 2.0 controller";
}

fn ehciAttach(dev: *pci.PciDev, unit: u32, self_dev: *const subr_bus.Device) bool {
    _ = unit;
    const cap: u64 = arch.pmap.mapdev(dev.bars[0].base, dev.bars[0].size) orelse return false;
    const op: u64 = cap + (rd4(cap, EHCI_CAPLENGTH) & 0xff);
    pci.enable_busmaster(dev);
    const released: bool = takeController(dev, cap);

    wr4(op, EHCI_USBINTR, 0);
    wr4(op, EHCI_USBCMD, rd4(op, EHCI_USBCMD) & ~EHCI_CMD_RS);
    var i: u32 = 0;
    while (i < 200 and (rd4(op, EHCI_USBSTS) & EHCI_STS_HCH) == 0) : (i += 1) arch.clock.DELAY(100);
    wr4(op, EHCI_USBSTS, rd4(op, EHCI_USBSTS)); // acknowledge whatever is pending

    if (!released) subr_bus.device_printf(self_dev, "BIOS did not release the controller\n", .{});
    subr_bus.device_printf(self_dev, "stopped (no EHCI driver yet)\n", .{});
    return true;
}

var ehci_driver: pci.Driver = .{
    .name = "ehci",
    .probe = ehciProbe,
    .attach = ehciAttach,
};

fn ehciRegister(_: ?*const anyopaque) callconv(.c) void {
    pci.registerDriver(&ehci_driver);
}

comptime {
    sysinit.SYSINIT("sysinit_ehci_pci", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_MIDDLE, ehciRegister, null);
}
