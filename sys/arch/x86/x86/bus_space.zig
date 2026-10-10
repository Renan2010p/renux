// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent bus_space implementation for the x86 family.
//
// This is the Zig counterpart of sys/arch/x86/x86/bus_space.c in NetBSD,
// shared by every x86 port. It implements the operations that sys/sys/bus.zig
// exposes to machine-independent drivers. Reads and writes are performed
// through the relevant architecture primitive (in/out for I/O port space,
// volatile memory access for memory-mapped space).

const defs: type = @import("../include/bus_defs.zig");

/// Re-exported MD types, consumed by sys/sys/bus.zig.
pub const bus_addr_t: type = defs.bus_addr_t;
pub const bus_size_t: type = defs.bus_size_t;
pub const Handle: type = defs.bus_space_handle_t;
pub const Tag: type = defs.Tag;
pub const tag_io: Tag = defs.tag_io;
pub const tag_mem: Tag = defs.tag_mem;

/// Read one byte from an x86 I/O port.
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Write one byte to an x86 I/O port.
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

/// Map a region of bus space.
///
/// I/O port and memory space are both identity mapped at this stage; the
/// memory case will need to carve out a real MMIO window once virtual memory
/// management exists.
pub fn map(tag: Tag, addr: bus_addr_t, size: bus_size_t, handle: *Handle) void {
    _ = size;
    switch (tag) {
        .io => handle.* = addr,
        .mem => handle.* = addr,
    }
}

/// Tear down a mapping. Identity mappings need no teardown yet.
pub fn unmap(tag: Tag, handle: Handle, size: bus_size_t) void {
    _ = tag;
    _ = handle;
    _ = size;
}

/// Read a single byte from mapped bus space.
pub fn read1(tag: Tag, handle: Handle, offset: bus_size_t) u8 {
    const addr: u64 = handle + offset;
    return switch (tag) {
        .io => inb(@intCast(addr)),
        .mem => @as(*volatile u8, @ptrFromInt(addr)).*,
    };
}

/// Write a single byte to mapped bus space.
pub fn write1(tag: Tag, handle: Handle, offset: bus_size_t, value: u8) void {
    const addr: u64 = handle + offset;
    switch (tag) {
        .io => outb(@intCast(addr), value),
        .mem => @as(*volatile u8, @ptrFromInt(addr)).* = value,
    }
}
