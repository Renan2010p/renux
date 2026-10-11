// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// MI NS16550-compatible UART driver.
//
// Mirrors the role of sys/dev/ic/com.c in NetBSD. The driver is machine
// independent: it reaches its registers only through bus_space (sys/sys/bus.zig)
// and never issues in/out or touches a physical address directly. The MD port
// attaches a specific port (see arch/amd64/amd64/consinit.zig).

const bus: type = @import("../../sys/bus.zig");
const cons: type = @import("../cons.zig");

/// A physical NS16550 register window.
pub const Port: type = struct {
    /// Bus space the registers live in.
    tag: bus.bus_space_tag_t,
    /// Base bus address of the register window (I/O port or MMIO base).
    iobase: bus.bus_addr_t,
};

// Register offsets within an NS16550 register window.
const REG_DATA: bus.bus_size_t = 0; // RBR/THR (DLAB=0), DLL (DLAB=1)
const REG_IER: bus.bus_size_t = 1; // IER (DLAB=0), DLM (DLAB=1)
const REG_FCR: bus.bus_size_t = 2; // FIFO control
const REG_LCR: bus.bus_size_t = 3; // line control
const REG_MCR: bus.bus_size_t = 4; // modem control
const REG_LSR: bus.bus_size_t = 5; // line status

const LCR_DLAB: u8 = 0x80;
const LCR_8N1: u8 = 0x03;
const FCR_ENABLE_CLEAR: u8 = 0xc7;
const MCR_DTR_RTS: u8 = 0x03;
const LSR_THRE: u8 = 0x20; // transmitter holding register empty
const LSR_RXRDY: u8 = 0x01; // receiver data ready

/// The port the driver is currently attached to. Valid after init().
var attached: Port = undefined;

/// Handle returned by bus_space_map() for the attached port.
var handle: bus.bus_space_handle_t = 0;

fn writeReg(offset: bus.bus_size_t, value: u8) void {
    bus.bus_space_write_1(attached.tag, handle, offset, value);
}

fn readReg(offset: bus.bus_size_t) u8 {
    return bus.bus_space_read_1(attached.tag, handle, offset);
}

/// Initialise the UART at 115200 8N1 with FIFOs enabled.
pub fn init(port: Port) void {
    attached = port;
    bus.bus_space_map(port.tag, port.iobase, 8, &handle);

    writeReg(REG_IER, 0x00); // disable interrupts
    writeReg(REG_LCR, LCR_DLAB); // enable divisor latch access
    writeReg(REG_DATA, 0x01); // divisor low byte  -> 115200 baud
    writeReg(REG_IER, 0x00); // divisor high byte
    writeReg(REG_LCR, LCR_8N1); // 8 bits, no parity, one stop bit
    writeReg(REG_FCR, FCR_ENABLE_CLEAR); // enable + clear FIFOs
    writeReg(REG_MCR, MCR_DTR_RTS); // assert DTR and RTS
}

fn transmitterReady() bool {
    return (readReg(REG_LSR) & LSR_THRE) != 0;
}

/// Emit one character, blocking until the transmitter can accept it. A newline
/// is preceded by a carriage return, as console output requires.
pub fn putc(c: u8) void {
    if (c == '\n') {
        while (!transmitterReady()) {}
        writeReg(REG_DATA, '\r');
    }
    while (!transmitterReady()) {}
    writeReg(REG_DATA, c);
}

/// The console descriptor for this driver, for cons.cn_attach().
pub fn console() cons.Console {
    return .{ .putc = putc, .getc = getc, .trygetc = tryGetc };
}

fn receiverReady() bool {
    return (readReg(REG_LSR) & LSR_RXRDY) != 0;
}

/// Receive one character, blocking until one is available.
pub fn getc() u8 {
    while (!receiverReady()) {}
    return readReg(REG_DATA);
}

/// Receive one character without blocking, or null if none is ready.
pub fn tryGetc() ?u8 {
    if (receiverReady()) {
        return readReg(REG_DATA);
    }
    return null;
}
