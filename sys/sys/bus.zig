// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// MI bus_space interface.
//
// This mirrors the role of sys/sys/bus.h in NetBSD: it gives device drivers a
// machine-independent way to access bus address spaces (x86 I/O port space and
// memory-mapped space) without embedding host-architecture details. The
// concrete tag and handle types, and the operations themselves, are supplied
// by the machine-dependent port (the moral equivalent of <machine/bus_defs.h>):
//
//   sys/arch/<arch>/include/bus_defs.zig   MD types (tags, handles, sizes)
//   sys/arch/<arch>/<arch>/bus_space.zig   MD implementation
//
// Drivers include this file and only ever name bus_space_* symbols. The
// machine dependence is resolved once, here, through the arch dispatch.

const arch: type = @import("../arch/arch.zig");
const impl: type = arch.bus_space;

/// A bus address: an address as seen on the bus (physical on PCI/ISA).
pub const bus_addr_t: type = impl.bus_addr_t;

/// A bus size, i.e. the length of a bus space mapping or transfer.
pub const bus_size_t: type = impl.bus_size_t;

/// Opaque tag describing a bus space.
pub const bus_space_tag_t: type = impl.Tag;

/// Opaque handle to a mapped region of bus space.
pub const bus_space_handle_t: type = impl.Handle;

/// Standard tag for the x86 I/O port address space.
pub const BUS_SPACE_IO: bus_space_tag_t = impl.tag_io;

/// Standard tag for memory-mapped address space.
pub const BUS_SPACE_MEM: bus_space_tag_t = impl.tag_mem;

/// Map `size` bytes of bus space at `addr` into `handle`.
///
/// The tag selects the space. Mapping never fails on the current ports; a
/// future revision will return an error once memory-mapped space needs real
/// MMIO windows.
pub inline fn bus_space_map(
    tag: bus_space_tag_t,
    addr: bus_addr_t,
    size: bus_size_t,
    handle: *bus_space_handle_t,
) void {
    impl.map(tag, addr, size, handle);
}

/// Tear down a mapping previously established with bus_space_map().
pub inline fn bus_space_unmap(
    tag: bus_space_tag_t,
    handle: bus_space_handle_t,
    size: bus_size_t,
) void {
    impl.unmap(tag, handle, size);
}

/// Read a single byte from mapped bus space at `offset`.
pub inline fn bus_space_read_1(
    tag: bus_space_tag_t,
    handle: bus_space_handle_t,
    offset: bus_size_t,
) u8 {
    return impl.read1(tag, handle, offset);
}

/// Write a single byte to mapped bus space at `offset`.
pub inline fn bus_space_write_1(
    tag: bus_space_tag_t,
    handle: bus_space_handle_t,
    offset: bus_size_t,
    value: u8,
) void {
    impl.write1(tag, handle, offset, value);
}
