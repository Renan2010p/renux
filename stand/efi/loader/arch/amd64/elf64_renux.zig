// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 kernel hand-off: page tables.
//
// The counterpart of FreeBSD's stand/efi/loader/arch/amd64/elf64_freebsd.c
// (named for the kernel it loads): the page tables the kernel starts on, an
// identity map (for the loader and the kernel's first instructions), the
// direct map (HHDM) the kernel uses for physical memory, and the kernel image
// at its link address, all with 2 MiB pages.

const std: type = @import("std");
const uefi: type = std.os.uefi;

/// The kernel image is placed on this boundary so 2 MiB pages can map it.
pub const KERNEL_ALIGN: u64 = 0x200000;

fn bs() *uefi.tables.BootServices {
    return uefi.system_table.boot_services.?;
}

fn newTable() ![*]u64 {
    const p = bs().allocatePages(.any, .loader_data, 1) catch return error.OutOfResources;
    const t: [*]u64 = @ptrCast(p.ptr);
    @memset(t[0..512], 0);
    return t;
}

fn nextTable(table: [*]u64, index: usize) ![*]u64 {
    if ((table[index] & 1) == 0) {
        table[index] = @intFromPtr(try newTable()) | 0x3; // P | RW
    }
    return @ptrFromInt(@as(usize, @intCast(table[index] & ~@as(u64, 0xfff))));
}

/// Map the 2 MiB page at virtual `virt` to physical `phys`.
fn map2M(pml4: [*]u64, virt: u64, phys: u64) !void {
    const pdpt: [*]u64 = try nextTable(pml4, @intCast((virt >> 39) & 0x1ff));
    const pd: [*]u64 = try nextTable(pdpt, @intCast((virt >> 30) & 0x1ff));
    pd[@intCast((virt >> 21) & 0x1ff)] = (phys & ~@as(u64, 0x1fffff)) | 0x83; // P | RW | PS
}

/// Build the kernel's initial page tables; returns the physical address of
/// the top-level table (the value for CR3). Physical memory up to `mem_max`
/// is mapped twice (identity and at `hhdm`), and the `span` bytes of the
/// kernel image at `phys_base` at its link address `vm_base`.
pub fn buildPageTables(mem_max: u64, hhdm: u64, vm_base: u64, phys_base: u64, span: u64) !u64 {
    const pml4: [*]u64 = try newTable();
    var pa: u64 = 0;
    while (pa < mem_max) : (pa += 0x200000) {
        try map2M(pml4, pa, pa);
        try map2M(pml4, hhdm + pa, pa);
    }
    var k: u64 = 0;
    while (k < span) : (k += 0x200000) {
        try map2M(pml4, vm_base + k, phys_base + k);
    }
    return @intFromPtr(pml4);
}
