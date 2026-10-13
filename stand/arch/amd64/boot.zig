// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux boot protocol (kernel side).
//
// The loader builds a `BootInfo` (see bootinfo.zig) and hands it to the kernel
// by request/response: the kernel emits a request object into the
// `.renux_requests` section, and the loader scans the loaded kernel for it and
// writes the BootInfo address into its `response` field.
//
// When `response` is null the kernel was started by a foreign loader (Limine),
// so every accessor falls back to the Limine protocol. This lets the same
// kernel boot under our own loader and under Limine while the loader matures.
//
// This is the Zig counterpart of FreeBSD's sys/sys/bootinfo.h plus the
// stand/ hand-off in stand/efi/loader/bootinfo.c.

const limine: type = @import("limine");
const bootinfo: type = @import("bootinfo.zig");

// Re-export the shared protocol types under the names the kernel uses.
pub const MAGIC: u64 = bootinfo.MAGIC;
pub const MemmapEntry: type = bootinfo.MemmapEntry;
pub const Framebuffer: type = bootinfo.Framebuffer;
pub const File: type = bootinfo.File;
pub const BootInfo: type = bootinfo.BootInfo;

/// The single request the loader looks for. Emitted into `.renux_requests`,
/// which the linker script places in the loaded image.
export var boot_request: bootinfo.Request align(8) linksection(".renux_requests") = .{
    .id = bootinfo.requestId(),
    .revision = bootinfo.revision,
    .response = null,
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

/// True when the Renux loader (stand/efi/loader) booted the kernel, false for
/// a foreign loader (Limine).
pub fn renuxLoader() bool {
    return info() != null;
}

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

/// True when memory map entry `e` is RAM: free memory, or memory the loader
/// and the kernel image occupy (what FreeBSD reports as "real memory"). The
/// two protocols number the types differently.
pub fn memmapIsRam(e: *const MemmapEntry) bool {
    if (info() != null) {
        return e.type == MemmapEntry.USABLE or e.type == MemmapEntry.BOOTLOADER_RECLAIMABLE or
            e.type == MemmapEntry.EXECUTABLE_AND_MODULES;
    }
    // Limine: USABLE 0, BOOTLOADER_RECLAIMABLE 5, EXECUTABLE_AND_MODULES 6.
    return e.type == 0 or e.type == 5 or e.type == 6;
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
    const m = limine.module(index) orelse return null;
    return @ptrCast(m);
}
