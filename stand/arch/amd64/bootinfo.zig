// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux boot protocol: the data the loader and the kernel agree on.
//
// This file is shared by both sides (stand/arch/amd64/boot.zig for the kernel,
// the loader in stand/amd64/uefi for the bootloader), so the layout cannot
// drift. It is the Zig counterpart of FreeBSD's sys/sys/bootinfo.h.

/// Marks a valid BootInfo.
pub const MAGIC: u64 = 0x5265_6e75_7842_6f6f; // "RenuxBoo"

/// Protocol revision.
pub const revision: u64 = 1;

/// The direct-map base the kernel expects (PML4 slot 273, like Linux/FreeBSD's
/// higher-half layouts).
pub const HHDM_OFFSET: u64 = 0xffff_8880_0000_0000;

/// A physical memory map entry.
pub const MemmapEntry: type = extern struct {
    base: u64,
    length: u64,
    type: u64,

    pub const USABLE: u64 = 0;
    pub const RESERVED: u64 = 1;
    pub const BOOTLOADER_RECLAIMABLE: u64 = 2;
    pub const EXECUTABLE_AND_MODULES: u64 = 3;
    pub const FRAMEBUFFER: u64 = 4;
};

/// A framebuffer the loader found.
pub const Framebuffer: type = extern struct {
    address: ?*anyopaque,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

/// A file the loader loaded (the kernel, or a module).
pub const File: type = extern struct {
    revision: u64,
    address: ?*anyopaque,
    size: u64,
    path: ?[*:0]const u8,
    string: ?[*:0]const u8,
    media_type: u32,
    unused: u32,
};

/// Everything the loader tells the kernel.
pub const BootInfo: type = extern struct {
    magic: u64,
    revision: u64,
    hhdm: u64,
    memmap: ?[*]MemmapEntry,
    memmap_count: u64,
    modules: ?[*]File,
    module_count: u64,
    framebuffers: ?[*]Framebuffer,
    framebuffer_count: u64,
    cmdline: ?[*:0]const u8,
    physical_base: u64,
    virtual_base: u64,
};

/// The four 64-bit words that identify the request object in the kernel image.
pub fn requestId() [4]u64 {
    return .{ 0x52656e7578424f4f, 0x50726f746f636f6c, 0x0000000000000001, 0x0000000000000001 };
}

/// The request object layout: id, revision, response pointer (offset 40).
pub const Request: type = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*BootInfo,

    /// Byte offset of the `response` field, for the loader to patch.
    pub const response_offset: usize = 40;
};
