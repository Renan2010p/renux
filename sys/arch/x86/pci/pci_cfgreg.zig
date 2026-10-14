// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// PCI configuration space access for x86.
//
// The Zig counterpart of FreeBSD's sys/x86/pci/pci_cfgreg.c, reduced to
// configuration mechanism #1: the address of a register goes to port 0xcf8
// and its value moves through port 0xcfc. Every PC chipset QEMU emulates
// has it; the memory-mapped ECAM window is not needed for bus 0.

const bus: type = @import("../../../sys/bus.zig");

/// Configuration address and data ports.
const CONF1_ADDR_PORT: u64 = 0x0cf8;
const CONF1_DATA_PORT: u64 = 0x0cfc;

/// The address of configuration register `reg` of bus/slot/func.
fn address(b: u8, slot: u8, func: u8, reg: u16) u32 {
    return 0x8000_0000 | (@as(u32, b) << 16) | (@as(u32, slot & 0x1f) << 11) |
        (@as(u32, func & 0x7) << 8) | (reg & 0xfc);
}

/// Read `bytes` (1, 2 or 4) of configuration register `reg`.
pub fn pci_cfgregread(b: u8, slot: u8, func: u8, reg: u16, bytes: u8) u32 {
    const io = bus.BUS_SPACE_IO;
    bus.bus_space_write_4(io, CONF1_ADDR_PORT, 0, address(b, slot, func, reg));
    const port: u64 = CONF1_DATA_PORT + (reg & 3);
    return switch (bytes) {
        1 => bus.bus_space_read_1(io, port, 0),
        2 => bus.bus_space_read_2(io, port, 0),
        else => bus.bus_space_read_4(io, CONF1_DATA_PORT, 0),
    };
}

/// Write `bytes` (1, 2 or 4) of `data` to configuration register `reg`.
pub fn pci_cfgregwrite(b: u8, slot: u8, func: u8, reg: u16, data: u32, bytes: u8) void {
    const io = bus.BUS_SPACE_IO;
    bus.bus_space_write_4(io, CONF1_ADDR_PORT, 0, address(b, slot, func, reg));
    const port: u64 = CONF1_DATA_PORT + (reg & 3);
    switch (bytes) {
        1 => bus.bus_space_write_1(io, port, 0, @truncate(data)),
        2 => bus.bus_space_write_2(io, port, 0, @truncate(data)),
        else => bus.bus_space_write_4(io, CONF1_DATA_PORT, 0, data),
    }
}
