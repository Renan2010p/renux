// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// PS/2 controller (i8042).
//
// The Zig counterpart of NetBSD's sys/dev/ic/pckbc.c, reduced to what the
// keyboard needs: register access through bus_space and a minimal bring-up
// (flush, enable the keyboard port, enable IRQ 1).

const bus: type = @import("../../sys/bus.zig");

/// Keyboard/mouse data port.
pub const DATA_PORT: u16 = 0x60;
/// Status (read) and command (write) port.
pub const CMD_PORT: u16 = 0x64;

/// Status register bits.
pub const STATUS_OUTPUT_FULL: u8 = 0x01; // a byte is available in DATA_PORT
pub const STATUS_INPUT_FULL: u8 = 0x02; // the controller cannot accept a byte
pub const STATUS_AUX: u8 = 0x20; // the available byte is from the mouse

// Controller commands.
const CMD_READ_CONFIG: u8 = 0x20;
const CMD_WRITE_CONFIG: u8 = 0x60;
const CMD_ENABLE_AUX: u8 = 0xa8;
const CMD_ENABLE_KBD: u8 = 0xae;

fn inb(port: u16) u8 {
    return bus.bus_space_read_1(bus.BUS_SPACE_IO, port, 0);
}

fn outb(port: u16, value: u8) void {
    bus.bus_space_write_1(bus.BUS_SPACE_IO, port, 0, value);
}

/// Read the status register.
pub fn status() u8 {
    return inb(CMD_PORT);
}

/// Read one byte from the data port.
pub fn readData() u8 {
    return inb(DATA_PORT);
}

/// Throw away any bytes already pending.
fn flush() void {
    var i: usize = 0;
    while (i < 64 and (status() & STATUS_OUTPUT_FULL) != 0) : (i += 1) {
        _ = readData();
    }
}

fn waitInput() void {
    while ((status() & STATUS_INPUT_FULL) != 0) {}
}

fn waitOutput() void {
    while ((status() & STATUS_OUTPUT_FULL) == 0) {}
}

fn writeCmd(cmd: u8) void {
    waitInput();
    outb(CMD_PORT, cmd);
}

fn writeData(data: u8) void {
    waitInput();
    outb(DATA_PORT, data);
}

/// Bring up the controller for the keyboard.
pub fn init() void {
    flush();
    writeCmd(CMD_ENABLE_AUX);
    writeCmd(CMD_ENABLE_KBD);

    // Enable the keyboard interrupt (config bit 0), keeping scan code
    // translation as the firmware set it.
    writeCmd(CMD_READ_CONFIG);
    waitOutput();
    var config: u8 = readData();
    config |= 0x01;
    config &= ~@as(u8, 0x10);
    writeCmd(CMD_WRITE_CONFIG);
    writeData(config);

    flush();
}
