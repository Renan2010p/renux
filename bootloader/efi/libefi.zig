// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Small helpers over the UEFI boot services.
//
// The counterpart of the allocation and table helpers in FreeBSD's
// stand/efi/libefi. Every part of the loader that talks to the firmware
// directly (the console, the ELF loader, the hand-off and the machine-dependent
// page-table code) imports this module as "libefi", so the firmware is
// reached in one way everywhere.
//
// All of it is only valid before ExitBootServices: afterwards the boot
// services are gone.

const std: type = @import("std");
const uefi: type = std.os.uefi;

/// The UEFI page size. UEFI allocates memory in units of 4 KiB pages on every
/// architecture.
pub const PAGE_SIZE: usize = 4096;

/// A run of whole UEFI pages.
pub const Pages: type = []align(PAGE_SIZE) uefi.Page;

/// The firmware's boot services table.
pub fn bootServices() *uefi.tables.BootServices {
    return uefi.system_table.boot_services.?;
}

/// The number of pages needed to hold `bytes` bytes.
pub fn pagesFor(bytes: u64) usize {
    return @intCast((bytes + PAGE_SIZE - 1) / PAGE_SIZE);
}

/// Allocate `count` pages of loader memory anywhere in physical memory.
///
/// The memory is typed `loader_data`, which the hand-off reports to the
/// kernel as BOOTLOADER_RECLAIMABLE: the kernel keeps it while it still uses
/// what the loader left there (its page tables, the BootInfo, its stack).
/// Returns null when the firmware is out of memory.
pub fn allocatePages(count: usize) ?Pages {
    return bootServices().allocatePages(.any, .loader_data, count) catch null;
}

/// Allocate `count` pages and fill them with zeros.
pub fn allocateZeroedPages(count: usize) ?Pages {
    const pages: Pages = allocatePages(count) orelse return null;
    const bytes: [*]u8 = @ptrCast(pages.ptr);
    @memset(bytes[0 .. count * PAGE_SIZE], 0);
    return pages;
}

/// Give pages from `allocatePages` back to the firmware.
pub fn freePages(pages: Pages) void {
    bootServices().freePages(pages) catch {};
}

/// The physical address of `ptr`. While the firmware runs, the loader runs on
/// the firmware's identity map, so a pointer is its own physical address.
pub fn physicalAddress(ptr: anytype) u64 {
    return @intFromPtr(ptr);
}

/// Round `value` up to a multiple of `alignment` (a power of two).
pub fn alignUp(value: u64, alignment: u64) u64 {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Copy a UCS-2 string from the firmware into `buf` as ASCII, replacing
/// every character outside ASCII with '?'. Stops at a NUL, at the end of
/// `text`, or when `buf` is full, and returns the part of `buf` written.
pub fn ucs2ToAscii(text: []const u16, buf: []u8) []const u8 {
    var len: usize = 0;
    for (text) |c| {
        if (c == 0 or len == buf.len) break;
        buf[len] = if (c < 0x80) @intCast(c) else '?';
        len += 1;
    }
    return buf[0..len];
}
