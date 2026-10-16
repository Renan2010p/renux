// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The kernel's initial page tables on amd64.
//
// The counterpart of FreeBSD's stand/efi/loader/arch/amd64/elf64_freebsd.c
// (named after the kernel it loads). The kernel starts on page tables that
// map three things, all with 2 MiB pages:
//
//   identity    physical memory at virtual = physical, so the instructions
//               right after the switch to these tables (still in the loader)
//               and the kernel's first instructions keep running;
//   direct map  physical memory again at `direct_map_base` (the HHDM), which
//               the kernel uses to reach any physical address;
//   kernel      the kernel image at the virtual address it was linked for.
//
// amd64 four-level paging: a virtual address is split into four 9-bit table
// indices (PML4, PDPT, PD, PT) and a 12-bit page offset. A PD entry with the
// PS bit maps a whole 2 MiB page and ends the walk there, so no PT is needed.

const libefi: type = @import("libefi");

/// A 2 MiB ("large") page.
pub const LARGE_PAGE_SIZE: u64 = 2 * 1024 * 1024;

/// Entries in every level of the page-table tree.
const ENTRIES_PER_TABLE: usize = 512;

// Page-table entry bits (Intel SDM vol. 3, "4-Level Paging").
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITABLE: u64 = 1 << 1;
const PTE_PAGE_SIZE: u64 = 1 << 7; // in a PD entry: maps a 2 MiB page
/// The physical address held in a table entry (bits 12 and up, below the
/// flag bits at the top that this loader never sets).
const PTE_ADDRESS_MASK: u64 = 0x000f_ffff_ffff_f000;

// Where each level's index sits in a virtual address.
const PML4_SHIFT: u6 = 39;
const PDPT_SHIFT: u6 = 30;
const PD_SHIFT: u6 = 21;
const INDEX_MASK: u64 = ENTRIES_PER_TABLE - 1;

/// What the kernel's initial page tables map. All values are multiples of
/// `LARGE_PAGE_SIZE` except `kernel_size`, which is rounded up.
pub const PageTableLayout: type = struct {
    /// Physical memory [0, direct_map_end) is mapped twice: at identity and
    /// at `direct_map_base`.
    direct_map_end: u64,
    direct_map_base: u64,
    /// The `kernel_size` bytes at physical `kernel_phys_base` are mapped at
    /// virtual `kernel_virt_base`.
    kernel_virt_base: u64,
    kernel_phys_base: u64,
    kernel_size: u64,
};

/// A page table: one page of 512 entries.
const Table: type = *[ENTRIES_PER_TABLE]u64;

/// A new, empty page table.
fn newTable() error{OutOfMemory}!Table {
    const page: libefi.Pages = libefi.allocateZeroedPages(1) orelse return error.OutOfMemory;
    return @ptrCast(page.ptr);
}

/// The table that entry `index` of `table` points to, created if missing.
fn nextTable(table: Table, index: usize) error{OutOfMemory}!Table {
    if ((table[index] & PTE_PRESENT) == 0) {
        table[index] = libefi.physicalAddress(try newTable()) | PTE_PRESENT | PTE_WRITABLE;
    }
    return @ptrFromInt(@as(usize, @intCast(table[index] & PTE_ADDRESS_MASK)));
}

/// Map the 2 MiB page at virtual address `virt` to physical address `phys`.
fn mapLargePage(pml4: Table, virt: u64, phys: u64) error{OutOfMemory}!void {
    const pdpt: Table = try nextTable(pml4, @intCast((virt >> PML4_SHIFT) & INDEX_MASK));
    const pd: Table = try nextTable(pdpt, @intCast((virt >> PDPT_SHIFT) & INDEX_MASK));
    pd[@intCast((virt >> PD_SHIFT) & INDEX_MASK)] = (phys & ~(LARGE_PAGE_SIZE - 1)) | PTE_PRESENT | PTE_WRITABLE | PTE_PAGE_SIZE;
}

/// Build the kernel's initial page tables as `layout` describes, and return
/// the physical address of the top-level table (the PML4), the value for CR3.
pub fn buildPageTables(layout: PageTableLayout) error{OutOfMemory}!u64 {
    const pml4: Table = try newTable();

    var phys: u64 = 0;
    while (phys < layout.direct_map_end) : (phys += LARGE_PAGE_SIZE) {
        try mapLargePage(pml4, phys, phys);
        try mapLargePage(pml4, layout.direct_map_base + phys, phys);
    }

    var offset: u64 = 0;
    while (offset < layout.kernel_size) : (offset += LARGE_PAGE_SIZE) {
        try mapLargePage(pml4, layout.kernel_virt_base + offset, layout.kernel_phys_base + offset);
    }

    return libefi.physicalAddress(pml4);
}
