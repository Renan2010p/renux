// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Bus definitions for the x86 family.
//
// This is the Zig counterpart of sys/arch/x86/include/bus_defs.h in NetBSD:
// it is shared by every x86 port (i386, amd64, ...).
//
// Only the types needed by early drivers are defined. It will grow alongside
// bus_space.zig and bus_dma.zig.

/// Bus address (a physical address on the bus).
pub const bus_addr_t: type = u64;

/// Bus size, for the length of mappings and transfers.
pub const bus_size_t: type = usize;

/// Handle for a mapped region of bus space. On x86 this is a virtual address.
pub const bus_space_handle_t: type = u64;

/// Selects which bus address space a tag refers to.
pub const Tag: type = enum(u8) {
    /// x86 I/O port space (in/out instructions).
    io = 0,
    /// Memory-mapped space.
    mem = 1,
};

/// The default I/O port tag.
pub const tag_io: Tag = .io;

/// The default memory-mapped tag.
pub const tag_mem: Tag = .mem;
