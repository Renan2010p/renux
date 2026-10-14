// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// VirtIO over PCI, legacy interface.
//
// The Zig counterpart of FreeBSD's sys/dev/virtio/pci/virtio_pci_legacy.c:
// the transport of the VirtIO 0.9.5 ("legacy") interface, which every
// transitional QEMU device offers through its I/O port BAR 0. It resets and
// acknowledges the device, negotiates features, hands virtqueues to the
// device by page frame number and rings their doorbell, then attaches the
// driver for the device type (vtblk for block devices).

const bus: type = @import("../../../sys/bus.zig");
const subr_bus: type = @import("../../../core/subr_bus.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");
const pci: type = @import("../../pci/pci.zig");
const virtio: type = @import("../virtio.zig");
const virtqueue: type = @import("../virtqueue.zig");
const vtblk: type = @import("../block/virtio_blk.zig");

/// Red Hat / Qumranet, and the legacy and transitional device ids.
const VIRTIO_VENDORID: u16 = 0x1af4;
const VIRTIO_DEVICEID_MIN: u16 = 0x1000;
const VIRTIO_DEVICEID_MAX: u16 = 0x103f;

/// Legacy register offsets (virtio_pci_legacy_var.h).
const VIRTIO_PCI_HOST_FEATURES: u64 = 0;
const VIRTIO_PCI_GUEST_FEATURES: u64 = 4;
const VIRTIO_PCI_QUEUE_PFN: u64 = 8;
const VIRTIO_PCI_QUEUE_NUM: u64 = 12;
const VIRTIO_PCI_QUEUE_SEL: u64 = 14;
const VIRTIO_PCI_QUEUE_NOTIFY: u64 = 16;
const VIRTIO_PCI_STATUS: u64 = 18;
const VIRTIO_PCI_ISR: u64 = 19;
/// Device-specific configuration, when MSI-X is off.
const VIRTIO_PCI_CONFIG: u64 = 20;
const VIRTIO_PCI_QUEUE_ADDR_SHIFT: u6 = 12;

/// A legacy VirtIO PCI device: what a child driver talks to.
pub const Vtpci: type = struct {
    iobase: u64,
    /// "virtio_pci<unit>", the child's parent name.
    nameunit: [16]u8,
    nameunit_len: usize,

    pub fn parentName(self: *const Vtpci) []const u8 {
        return self.nameunit[0..self.nameunit_len];
    }

    fn rd1(self: *const Vtpci, off: u64) u8 {
        return bus.bus_space_read_1(bus.BUS_SPACE_IO, self.iobase, off);
    }
    fn wr1(self: *const Vtpci, off: u64, v: u8) void {
        bus.bus_space_write_1(bus.BUS_SPACE_IO, self.iobase, off, v);
    }

    pub fn getStatus(self: *const Vtpci) u8 {
        return self.rd1(VIRTIO_PCI_STATUS);
    }

    /// Add `bits` to the device status (or reset it with 0).
    pub fn setStatus(self: *const Vtpci, bits: u8) void {
        const v: u8 = if (bits == virtio.VIRTIO_CONFIG_STATUS_RESET) 0 else self.getStatus() | bits;
        self.wr1(VIRTIO_PCI_STATUS, v);
    }

    /// Accept the features in `want` that the device offers; returns them.
    pub fn negotiateFeatures(self: *const Vtpci, want: u32) u32 {
        const host: u32 = bus.bus_space_read_4(bus.BUS_SPACE_IO, self.iobase, VIRTIO_PCI_HOST_FEATURES);
        const features: u32 = host & want;
        bus.bus_space_write_4(bus.BUS_SPACE_IO, self.iobase, VIRTIO_PCI_GUEST_FEATURES, features);
        return features;
    }

    /// Read `n` bytes of the device-specific configuration at `off`.
    pub fn readDevConfig(self: *const Vtpci, off: u64, dst: []u8) void {
        for (dst, 0..) |*b, i| b.* = self.rd1(VIRTIO_PCI_CONFIG + off + i);
    }

    /// Set up virtqueue `index` with the size the device gives it.
    pub fn allocVirtqueue(self: *Vtpci, vq: *virtqueue.Virtqueue, index: u16) bool {
        bus.bus_space_write_2(bus.BUS_SPACE_IO, self.iobase, VIRTIO_PCI_QUEUE_SEL, index);
        const num: u16 = bus.bus_space_read_2(bus.BUS_SPACE_IO, self.iobase, VIRTIO_PCI_QUEUE_NUM);
        if (num == 0) return false;
        if (!virtqueue.alloc(vq, index, num, notify, self)) return false;
        bus.bus_space_write_4(bus.BUS_SPACE_IO, self.iobase, VIRTIO_PCI_QUEUE_PFN, @intCast(vq.paddr >> VIRTIO_PCI_QUEUE_ADDR_SHIFT));
        return true;
    }

    fn notify(ctx: ?*anyopaque, index: u16) void {
        const self: *Vtpci = @ptrCast(@alignCast(ctx.?));
        bus.bus_space_write_2(bus.BUS_SPACE_IO, self.iobase, VIRTIO_PCI_QUEUE_NOTIFY, index);
    }

    /// Acknowledge a (polled) interrupt by reading the ISR.
    pub fn ackInterrupt(self: *const Vtpci) void {
        _ = self.rd1(VIRTIO_PCI_ISR);
    }
};

const MAXUNITS: usize = 4;
var softc: [MAXUNITS]Vtpci = undefined;

/// The device type of a legacy device: its PCI subsystem id.
fn deviceType(dev: *const pci.PciDev) u16 {
    return dev.subdevice;
}

fn vtpciProbe(dev: *const pci.PciDev) ?[]const u8 {
    if (dev.vendor != VIRTIO_VENDORID) return null;
    if (dev.device < VIRTIO_DEVICEID_MIN or dev.device > VIRTIO_DEVICEID_MAX) return null;
    if (!dev.bars[0].io) return null;
    return switch (deviceType(dev)) {
        virtio.VIRTIO_ID_BLOCK => "VirtIO PCI (legacy) Block adapter",
        else => null, // no driver for the type yet: left unattached
    };
}

fn vtpciAttach(dev: *pci.PciDev, unit: u32, self_dev: *const subr_bus.Device) bool {
    _ = self_dev;
    if (unit >= MAXUNITS) return false;
    const sc: *Vtpci = &softc[unit];
    sc.* = .{ .iobase = dev.bars[0].base, .nameunit = undefined, .nameunit_len = 0 };
    const prefix: []const u8 = "virtio_pci";
    @memcpy(sc.nameunit[0..prefix.len], prefix);
    sc.nameunit[prefix.len] = @intCast('0' + unit);
    sc.nameunit_len = prefix.len + 1;

    pci.enable_busmaster(dev);
    sc.setStatus(virtio.VIRTIO_CONFIG_STATUS_RESET);
    sc.setStatus(virtio.VIRTIO_CONFIG_STATUS_ACK);
    sc.setStatus(virtio.VIRTIO_CONFIG_STATUS_DRIVER);

    const ok: bool = switch (deviceType(dev)) {
        virtio.VIRTIO_ID_BLOCK => vtblk.attach(sc),
        else => false,
    };
    if (!ok) {
        sc.setStatus(virtio.VIRTIO_CONFIG_STATUS_FAILED);
        return false;
    }
    return true;
}

var vtpci_driver: pci.Driver = .{
    .name = "virtio_pci",
    .probe = vtpciProbe,
    .attach = vtpciAttach,
};

fn vtpciRegister(_: ?*const anyopaque) callconv(.c) void {
    pci.registerDriver(&vtpci_driver);
}

comptime {
    sysinit.SYSINIT("sysinit_virtio_pci", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_MIDDLE, vtpciRegister, null);
}
