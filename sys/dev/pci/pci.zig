// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// PCI bus.
//
// The Zig counterpart of FreeBSD's sys/dev/pci/pci.c, reduced to what a
// virtual machine's bus needs: scan bus 0 through the port's configuration
// access (arch.pci_cfgreg), size each function's BARs, offer every function
// to the registered drivers, and report it the way FreeBSD does:
//
//   pcib0: <Host to PCI bridge> pcibus 0 on motherboard
//   pci0: <PCI bus> on pcib0
//   virtio_pci0: <VirtIO PCI (legacy) Block adapter> port 0xc000-0xc07f irq 11 at device 4.0 on pci0
//   pci0: <network, ethernet> at device 3.0 (no driver attached)

const arch: type = @import("../../arch/arch.zig");
const prf: type = @import("../../kern/subr_prf.zig");
const subr_bus: type = @import("../../kern/subr_bus.zig");
const sysinit: type = @import("../../sys/sysinit.zig");

/// Configuration space registers (pcireg.h).
pub const PCIR_VENDOR: u16 = 0x00;
pub const PCIR_DEVICE: u16 = 0x02;
pub const PCIR_COMMAND: u16 = 0x04;
pub const PCIR_REVID: u16 = 0x08;
pub const PCIR_PROGIF: u16 = 0x09;
pub const PCIR_SUBCLASS: u16 = 0x0a;
pub const PCIR_CLASS: u16 = 0x0b;
pub const PCIR_HDRTYPE: u16 = 0x0e;
pub const PCIR_BAR0: u16 = 0x10;
pub const PCIR_SUBVEND_0: u16 = 0x2c;
pub const PCIR_SUBDEV_0: u16 = 0x2e;
pub const PCIR_INTLINE: u16 = 0x3c;

/// Command register bits.
pub const PCIM_CMD_PORTEN: u16 = 0x0001;
pub const PCIM_CMD_MEMEN: u16 = 0x0002;
pub const PCIM_CMD_BUSMASTEREN: u16 = 0x0004;

/// Header type: multi-function device.
const PCIM_MFDEV: u8 = 0x80;

pub const PCI_MAXSLOTS: u8 = 32;
pub const PCI_MAXBARS: usize = 6;

/// A decoded base address register.
pub const Bar: type = struct {
    /// I/O port space (true) or memory space (false).
    io: bool = false,
    base: u64 = 0,
    size: u64 = 0,
};

/// A PCI function (the part of FreeBSD's struct pci_devinfo drivers use).
pub const PciDev: type = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device: u16,
    subvendor: u16,
    subdevice: u16,
    class: u8,
    subclass: u8,
    progif: u8,
    revid: u8,
    irq: u8,
    bars: [PCI_MAXBARS]Bar,
    /// The driver that attached, if any.
    attached: bool = false,
};

/// A PCI driver: `probe` returns the device description when it handles the
/// function; `attach` then brings it up, as unit `unit` of the driver.
pub const Driver: type = struct {
    name: []const u8,
    probe: *const fn (dev: *const PciDev) ?[]const u8,
    attach: *const fn (dev: *PciDev, unit: u32, self: *const subr_bus.Device) bool,
    /// Units attached so far.
    units: u32 = 0,
};

const MAXDRIVERS: usize = 8;
var drivers: [MAXDRIVERS]*Driver = undefined;
var ndrivers: usize = 0;

/// Functions found on the bus.
const MAXDEVS: usize = 32;
var devs: [MAXDEVS]PciDev = undefined;
var ndevs: usize = 0;

/// Register a driver; called from the driver's SYSINIT at SI_SUB_DRIVERS,
/// before the bus is scanned (FreeBSD's DRIVER_MODULE).
pub fn registerDriver(d: *Driver) void {
    if (ndrivers < MAXDRIVERS) {
        drivers[ndrivers] = d;
        ndrivers += 1;
    }
}

pub fn read_config(dev: *const PciDev, reg: u16, width: u8) u32 {
    return arch.pci_cfgreg.pci_cfgregread(dev.bus, dev.slot, dev.func, reg, width);
}

pub fn write_config(dev: *const PciDev, reg: u16, val: u32, width: u8) void {
    arch.pci_cfgreg.pci_cfgregwrite(dev.bus, dev.slot, dev.func, reg, val, width);
}

/// Turn on I/O, memory decoding and bus mastering (DMA) for `dev`.
pub fn enable_busmaster(dev: *const PciDev) void {
    const cmd: u32 = read_config(dev, PCIR_COMMAND, 2);
    write_config(dev, PCIR_COMMAND, cmd | PCIM_CMD_PORTEN | PCIM_CMD_MEMEN | PCIM_CMD_BUSMASTEREN, 2);
}

/// Decode and size BAR `i`. Sizing writes all ones and reads back the mask
/// of writable bits, then restores the original value. Returns how many BAR
/// slots it used (2 for a 64-bit memory BAR).
fn readBar(dev: *PciDev, i: usize) usize {
    const reg: u16 = PCIR_BAR0 + @as(u16, @intCast(i)) * 4;
    const orig: u32 = read_config(dev, reg, 4);
    write_config(dev, reg, 0xffff_ffff, 4);
    const mask: u32 = read_config(dev, reg, 4);
    write_config(dev, reg, orig, 4);
    if (mask == 0 or (mask == 0xffff_ffff and orig == 0xffff_ffff)) return 1;

    if ((orig & 1) != 0) {
        // I/O space: 16-bit ports on x86.
        const m: u32 = (mask & 0xffff_fffc) | 0xffff_0000;
        dev.bars[i] = .{ .io = true, .base = orig & 0xffff_fffc, .size = @as(u64, ~m) + 1 };
        return 1;
    }
    var base: u64 = orig & 0xffff_fff0;
    var size_mask: u64 = 0xffff_ffff_0000_0000 | @as(u64, mask & 0xffff_fff0);
    var used: usize = 1;
    if (((orig >> 1) & 3) == 2 and i + 1 < PCI_MAXBARS) {
        // 64-bit memory BAR: the next slot holds the high half.
        const hreg: u16 = reg + 4;
        const horig: u32 = read_config(dev, hreg, 4);
        write_config(dev, hreg, 0xffff_ffff, 4);
        const hmask: u32 = read_config(dev, hreg, 4);
        write_config(dev, hreg, horig, 4);
        base |= @as(u64, horig) << 32;
        size_mask = (@as(u64, hmask) << 32) | @as(u64, mask & 0xffff_fff0);
        used = 2;
    }
    dev.bars[i] = .{ .io = false, .base = base, .size = ~size_mask +% 1 };
    return used;
}

/// The class names FreeBSD prints for functions no driver claims
/// (pci_nomatch_tab), for the classes a PC has.
fn className(class: u8, subclass: u8) []const u8 {
    return switch (class) {
        0x01 => switch (subclass) {
            0x01 => "storage, ATA",
            0x06 => "storage, SATA",
            0x00 => "storage, SCSI",
            0x08 => "storage, NVM",
            else => "storage",
        },
        0x02 => if (subclass == 0x00) "network, ethernet" else "network",
        0x03 => if (subclass == 0x00) "display, VGA" else "display",
        0x04 => if (subclass == 0x03) "multimedia, HDA" else "multimedia",
        0x06 => switch (subclass) {
            0x00 => "bridge, HOST-PCI",
            0x01 => "bridge, PCI-ISA",
            0x04 => "bridge, PCI-PCI",
            else => "bridge",
        },
        0x07 => "simple comms",
        0x08 => "base peripheral",
        0x0c => switch (subclass) {
            0x03 => "serial bus, USB",
            0x05 => "serial bus, SMBus",
            else => "serial bus",
        },
        else => "unknown",
    };
}

// -- resource list ----------------------------------------------------------------

var resbuf: [160]u8 = undefined;
var reslen: usize = 0;

fn resPut(s: []const u8) void {
    for (s) |c| {
        if (reslen < resbuf.len) {
            resbuf[reslen] = c;
            reslen += 1;
        }
    }
}

fn resHex(v: u64) void {
    resPut("0x");
    var started: bool = false;
    var shift: u7 = 60;
    while (true) : (shift -= 4) {
        const nib: u8 = @truncate((v >> @intCast(shift)) & 0xf);
        if (nib != 0 or started or shift == 0) {
            started = true;
            resPut(&[_]u8{"0123456789abcdef"[nib]});
        }
        if (shift == 0) break;
    }
}

fn resDec(v: u64) void {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x: u64 = v;
    while (true) {
        tmp[n] = @intCast('0' + x % 10);
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    while (n > 0) {
        n -= 1;
        resPut(tmp[n .. n + 1]);
    }
}

/// " port a-b mem c-d,e-f irq N at device S.F", as FreeBSD prints a PCI
/// child's resources.
fn resources(dev: *const PciDev) []const u8 {
    reslen = 0;
    var first: bool = true;
    for (dev.bars) |b| {
        if (!b.io or b.size == 0) continue;
        resPut(if (first) " port " else ",");
        first = false;
        resHex(b.base);
        resPut("-");
        resHex(b.base + b.size - 1);
    }
    first = true;
    for (dev.bars) |b| {
        if (b.io or b.size == 0) continue;
        resPut(if (first) " mem " else ",");
        first = false;
        resHex(b.base);
        resPut("-");
        resHex(b.base + b.size - 1);
    }
    if (dev.irq != 0 and dev.irq != 0xff) {
        resPut(" irq ");
        resDec(dev.irq);
    }
    resPut(" at device ");
    resDec(dev.slot);
    resPut(".");
    resDec(dev.func);
    return resbuf[0..reslen];
}

// -- enumeration -------------------------------------------------------------------

fn probeFunction(b: u8, slot: u8, func: u8) ?*PciDev {
    const vendor: u32 = arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_VENDOR, 2);
    if (vendor == 0xffff or ndevs >= MAXDEVS) return null;
    const dev: *PciDev = &devs[ndevs];
    ndevs += 1;
    dev.* = .{
        .bus = b,
        .slot = slot,
        .func = func,
        .vendor = @intCast(vendor),
        .device = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_DEVICE, 2)),
        .subvendor = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_SUBVEND_0, 2)),
        .subdevice = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_SUBDEV_0, 2)),
        .class = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_CLASS, 1)),
        .subclass = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_SUBCLASS, 1)),
        .progif = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_PROGIF, 1)),
        .revid = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_REVID, 1)),
        .irq = @intCast(arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_INTLINE, 1)),
        .bars = @splat(.{}),
    };
    // Only ordinary (type 0) headers have six BARs.
    const hdr: u32 = arch.pci_cfgreg.pci_cfgregread(b, slot, func, PCIR_HDRTYPE, 1) & 0x7f;
    if (hdr == 0) {
        var i: usize = 0;
        while (i < PCI_MAXBARS) i += readBar(dev, i);
    }
    return dev;
}

/// Offer `dev` to the drivers; report it either way.
fn attachDevice(dev: *PciDev) void {
    for (drivers[0..ndrivers]) |d| {
        const desc: []const u8 = d.probe(dev) orelse continue;
        const self: subr_bus.Device = .{ .name = d.name, .unit = d.units, .desc = desc, .parent = "pci0" };
        subr_bus.announce(&self, "%s", .{resources(dev)});
        if (d.attach(dev, d.units, &self)) {
            d.units += 1;
            dev.attached = true;
            return;
        }
    }
    // The host bridge is the bus's own parent (pcib0) and needs no line.
    if (dev.class == 0x06 and dev.subclass == 0x00) return;
    prf.printf("pci0: <%s> at device %u.%u (no driver attached)\n", .{ className(dev.class, dev.subclass), dev.slot, dev.func });
}

fn pciScan(_: ?*const anyopaque) callconv(.c) void {
    // A PC always has a host bridge at 0:0.0; without one there is no bus.
    if (arch.pci_cfgreg.pci_cfgregread(0, 0, 0, PCIR_VENDOR, 2) == 0xffff) return;
    prf.printLine("pcib0: <Host to PCI bridge> pcibus 0 on motherboard");
    prf.printLine("pci0: <PCI bus> on pcib0");

    var slot: u8 = 0;
    while (slot < PCI_MAXSLOTS) : (slot += 1) {
        const first: *PciDev = probeFunction(0, slot, 0) orelse continue;
        const hdr: u32 = arch.pci_cfgreg.pci_cfgregread(0, slot, 0, PCIR_HDRTYPE, 1);
        attachDevice(first);
        if ((hdr & PCIM_MFDEV) == 0) continue;
        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            const dev: *PciDev = probeFunction(0, slot, func) orelse continue;
            attachDevice(dev);
        }
    }
}

comptime {
    // After the ISA devices and the console, as FreeBSD's nexus attaches
    // the PCI bridge.
    sysinit.SYSINIT("sysinit_pci", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_MIDDLE, pciScan, null);
}
