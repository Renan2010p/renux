// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux boot protocol, kernel side.
//
// This module is compiled into the kernel (build.zig imports it as
// "renuxboot", and kernel/arch/amd64/conf/files.zig exposes it as
// `arch.boot`). It does two things:
//
//   1. It emits the request object the loader looks for (see bootinfo.zig for
//      how the loader finds it and answers).
//   2. It gives the rest of the kernel one set of accessors for what the
//      loader passed: the command line, the direct map, the memory map, the
//      framebuffer and the loaded files.
//
// Two loaders can start this kernel. When the Renux loader did, the request's
// `response` points at a BootInfo; when it is null, a foreign loader (Limine)
// did, and every accessor answers from the Limine protocol instead
// (bootloader/arch/amd64/limine/limine.zig). The accessors return null when
// the loader did not provide the information.
//
// This is the Zig counterpart of FreeBSD's sys/sys/bootinfo.h together with
// the hand-off in FreeBSD's stand/efi/loader/bootinfo.c.

const limine: type = @import("limine");
const bootinfo: type = @import("bootinfo.zig");

// The protocol types, under the names the kernel uses.
pub const MAGIC: u64 = bootinfo.MAGIC;
pub const MemmapEntry: type = bootinfo.MemmapEntry;
pub const Framebuffer: type = bootinfo.Framebuffer;
pub const File: type = bootinfo.File;
pub const BootInfo: type = bootinfo.BootInfo;

/// The one request the Renux loader looks for. It lives in `.renux_requests`,
/// which the kernel's linker script (kernel/arch/amd64/conf/kern.ldscript)
/// keeps in the loaded image.
export var boot_request: bootinfo.Request align(8) linksection(".renux_requests") = .{
    .id = bootinfo.requestId(),
    .revision = bootinfo.revision,
    .response = null,
};

/// The BootInfo the Renux loader supplied, or null when a foreign loader
/// started the kernel (or the answer does not carry the protocol's magic).
fn info() ?*const BootInfo {
    const response: *const BootInfo = boot_request.response orelse return null;
    if (response.magic != MAGIC) {
        return null;
    }
    return response;
}

/// The bytes of a NUL-terminated string, without the terminator.
fn span(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

// -- Accessors ---------------------------------------------------------------

/// True when the Renux loader (bootloader/efi) started the kernel; false for
/// a foreign loader (Limine).
pub fn renuxLoader() bool {
    return info() != null;
}

/// The kernel command line, e.g. "-v console=comconsole".
pub fn cmdline() ?[]const u8 {
    if (info()) |i| {
        const c: [*:0]const u8 = i.cmdline orelse return null;
        return span(c);
    }
    return limine.cmdline();
}

/// The virtual address at which all of physical memory is mapped.
pub fn hhdmOffset() ?u64 {
    if (info()) |i| {
        return i.hhdm;
    }
    return limine.hhdmOffset();
}

/// The number of entries in the physical memory map.
pub fn memmapEntryCount() ?usize {
    if (info()) |i| {
        return @intCast(i.memmap_count);
    }
    return limine.memmapEntryCount();
}

/// Entry `index` of the physical memory map.
pub fn memmapEntry(index: usize) ?*MemmapEntry {
    if (info()) |i| {
        if (index >= i.memmap_count) return null;
        const entries: [*]MemmapEntry = i.memmap orelse return null;
        return &entries[index];
    }
    // Limine's entry starts with the same three words (base, length, type).
    const entry: *limine.MemmapEntry = limine.memmapEntry(index) orelse return null;
    return @ptrCast(entry);
}

/// True when memory map entry `e` is RAM: free memory, or memory the loader
/// and the kernel image occupy (what FreeBSD reports as "real memory"). The
/// two protocols number the entry types differently.
pub fn memmapIsRam(e: *const MemmapEntry) bool {
    if (info() != null) {
        return switch (e.type) {
            MemmapEntry.USABLE, MemmapEntry.BOOTLOADER_RECLAIMABLE, MemmapEntry.EXECUTABLE_AND_MODULES => true,
            else => false,
        };
    }
    return switch (e.type) {
        limine.MemmapEntry.USABLE, limine.MemmapEntry.BOOTLOADER_RECLAIMABLE, limine.MemmapEntry.EXECUTABLE_AND_MODULES => true,
        else => false,
    };
}

/// The number of framebuffers.
pub fn framebufferCount() ?usize {
    if (info()) |i| {
        return @intCast(i.framebuffer_count);
    }
    return limine.framebufferCount();
}

/// Framebuffer `index`.
pub fn framebuffer(index: usize) ?*Framebuffer {
    if (info()) |i| {
        if (index >= i.framebuffer_count) return null;
        const framebuffers: [*]Framebuffer = i.framebuffers orelse return null;
        return &framebuffers[index];
    }
    // Limine's framebuffer starts with the same fields as ours.
    const fb: *limine.Framebuffer = limine.framebuffer(index) orelse return null;
    return @ptrCast(fb);
}

/// The number of files loaded with the kernel.
pub fn moduleCount() ?usize {
    if (info()) |i| {
        return @intCast(i.module_count);
    }
    return limine.moduleCount();
}

/// Loaded file `index`.
pub fn module(index: usize) ?*File {
    if (info()) |i| {
        if (index >= i.module_count) return null;
        const modules: [*]File = i.modules orelse return null;
        return &modules[index];
    }
    // Limine's file starts with the same fields as ours.
    const file: *limine.File = limine.module(index) orelse return null;
    return @ptrCast(file);
}
