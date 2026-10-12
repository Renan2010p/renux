// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux boot protocol (kernel side).
//
// The boot loader builds a `BootInfo` describing the machine (HHDM offset,
// physical memory map, framebuffer, modules, command line) and hands it to the
// kernel. The hand-off is by request/response: the kernel emits a request
// object into the `.renux_requests` section, and the loader scans the loaded
// kernel for it and writes the BootInfo address into its `response` field.
//
// When `response` is null the kernel was started by a foreign loader (Limine),
// so every accessor falls back to the Limine protocol. This lets the same
// kernel boot under our own loader and under Limine while the loader matures.
//
// This is the Zig counterpart of FreeBSD's sys/sys/bootinfo.h plus the
// stand/ hand-off in stand/efi/loader/bootinfo.c.

const limine: type = @import("limine");

/// Marks a valid BootInfo. Chosen so a stray read is unlikely to match.
pub const MAGIC: u64 = 0x5265_6e75_7842_6f6f; // "RenuxBoo"

/// Protocol revision this kernel understands.
pub const revision: u64 = 1;

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

/// A framebuffer the loader found (GOP, VBE, ...). Same geometry the kernel
/// already consumes from Limine.
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

/// A file the loader loaded (the kernel or a module). The layout matches the
/// leading fields of Limine's File, so the fallback can hand back a pointer to
/// one without copying.
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
    /// Direct-map (higher-half) offset: virtual = physical + hhdm.
    hhdm: u64,
    /// Physical memory map.
    memmap: ?[*]MemmapEntry,
    memmap_count: u64,
    /// Loaded modules (the embedded-root kernel needs none).
    modules: ?[*]File,
    module_count: u64,
    /// Framebuffer the loader selected.
    framebuffers: ?[*]Framebuffer,
    framebuffer_count: u64,
    /// Kernel command line.
    cmdline: ?[*:0]const u8,
    /// Where the kernel image was loaded.
    physical_base: u64,
    virtual_base: u64,
};

fn requestId(comptime a: u64, comptime b: u64) [4]u64 {
    return .{ 0x52656e7578424f4f, 0x50726f746f636f6c, a, b };
}

fn Request(comptime Response: type) type {
    return extern struct {
        id: [4]u64,
        revision: u64 = 0,
        response: ?*Response = null,
    };
}

/// The single request the loader looks for. Emitted into `.renux_requests`,
/// which the linker script places in the loaded image.
export var boot_request: Request(BootInfo) align(8) linksection(".renux_requests") = .{
    .id = requestId(0x0000000000000001, 0x0000000000000001),
};

/// The BootInfo the loader supplied, or null when a foreign loader booted us
/// (or the magic does not match).
fn info() ?*const BootInfo {
    const response = boot_request.response orelse return null;
    if (response.magic != MAGIC) {
        return null;
    }
    return response;
}

fn span(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

// -- Accessors ---------------------------------------------------------------

pub fn cmdline() ?[]const u8 {
    if (info()) |i| {
        const c = i.cmdline orelse return null;
        return span(c);
    }
    return limine.cmdline();
}

pub fn hhdmOffset() ?u64 {
    if (info()) |i| {
        return i.hhdm;
    }
    return limine.hhdmOffset();
}

pub fn memmapEntryCount() ?usize {
    if (info()) |i| {
        return @intCast(i.memmap_count);
    }
    return limine.memmapEntryCount();
}

pub fn memmapEntry(index: usize) ?*MemmapEntry {
    if (info()) |i| {
        if (index >= i.memmap_count) return null;
        const entries = i.memmap orelse return null;
        return &entries[index];
    }
    const m = limine.memmapEntry(index) orelse return null;
    return @ptrCast(m);
}

pub fn framebufferCount() ?usize {
    if (info()) |i| {
        return @intCast(i.framebuffer_count);
    }
    return limine.framebufferCount();
}

pub fn framebuffer(index: usize) ?*Framebuffer {
    if (info()) |i| {
        if (index >= i.framebuffer_count) return null;
        const fbs = i.framebuffers orelse return null;
        return &fbs[index];
    }
    const f = limine.framebuffer(index) orelse return null;
    return @ptrCast(f);
}

pub fn moduleCount() ?usize {
    if (info()) |i| {
        return @intCast(i.module_count);
    }
    return limine.moduleCount();
}

pub fn module(index: usize) ?*File {
    if (info()) |i| {
        if (index >= i.module_count) return null;
        const mods = i.modules orelse return null;
        return &mods[index];
    }
    // The foreign protocol's File has the same leading fields.
    const m = limine.module(index) orelse return null;
    return @ptrCast(m);
}
