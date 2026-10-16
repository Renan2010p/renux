// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Physical page allocator.
//
// This is the Zig counterpart of NetBSD's sys/uvm/vm_page.c. The state lives
// in a bitmap (see phys_bitmap.zig) rather than in the free pages themselves,
// so a stray write to a free page can no longer corrupt the allocator and a
// double free is detected instead of silently duplicating a page. Pages are
// reached through the higher-half direct map (HHDM) offset reported by the
// bootloader, and page zero is never handed out. Pages are handed out from the
// top down, like the boot loader arranges memory (the very low pages can still
// hold in-use boot structures that the memory map calls usable).

const param: type = @import("../sys/param.zig");
const addr: type = @import("../sys/addr.zig");
const phys: type = @import("phys_bitmap.zig");
const prf: type = @import("../core/subr_prf.zig");

/// The address types the allocator speaks: physical addresses out of the pool,
/// and the kernel virtual addresses the direct map gives them.
pub const PAddr = addr.PAddr;
pub const KAddr = addr.KAddr;
pub const Hhdm = addr.Hhdm;

/// The direct-map offset, held as an Hhdm so a stray u64 cannot take its
/// place.
var hhdm: addr.Hhdm = addr.Hhdm.fromInt(0);

/// The bitmaps cover up to 4 GiB (1 Mi bits, one per 4 KiB page).
var free_bits: [131072]u8 = undefined;
var present_bits: [131072]u8 = undefined;
var bm: phys.Bitmap = undefined;

/// One past the highest usable physical address seen by physload.
var mem_top: u64 = 0;

/// True when `pa` names an aligned 4 KiB page within the usable physical memory.
pub fn validPage(pa: PAddr) bool {
    const a: u64 = pa.int();
    return a != 0 and (a & (param.PAGE_SIZE - 1)) == 0 and
        mem_top >= param.PAGE_SIZE and a <= mem_top - param.PAGE_SIZE;
}

/// Prepare the allocator with the direct-map offset used to reach memory.
pub fn init(offset: addr.Hhdm) void {
    hhdm = offset;
    mem_top = 0;
    bm = phys.Bitmap.init(&free_bits, &present_bits, 0, @as(u64, free_bits.len) * 8);
    prf.log(prf.LOG_DEBUG, "vm_page: physical page allocator ready", .{});
}

/// Address of the direct-map view of physical page `pa`.
fn pagePtr(pa: PAddr) [*]u64 {
    return hhdm.kern(pa).manyPtr(u64);
}

/// Mark the pages in [start, end) as available.
pub fn physload(start: PAddr, end: PAddr) void {
    if (end.int() > mem_top) {
        mem_top = end.int();
    }
    bm.load(start.int(), end.int());
    // Page zero is never handed out.
    bm.unload(0, param.PAGE_SIZE);
}

/// Mark the pages in [start, end) as unavailable (carve out boot-loader modules
/// that land in memory the map still calls usable).
pub fn physunload(start: PAddr, end: PAddr) void {
    bm.unload(start.int(), end.int());
}

/// Allocate a zeroed 4 KiB page, or null when memory is exhausted.
pub fn physalloc() ?PAddr {
    const pa: PAddr = PAddr.fromInt(bm.alloc() orelse return null);
    const page: [*]u64 = pagePtr(pa);
    var i: usize = 0;
    while (i < param.PAGE_SIZE / 8) : (i += 1) {
        page[i] = 0;
    }
    return pa;
}

/// Allocate a page without zeroing it, for a caller that overwrites all of
/// it at once (fork's page copies). Never hand such a page to user space
/// before filling it.
pub fn physallocUninit() ?PAddr {
    return PAddr.fromInt(bm.alloc() orelse return null);
}

/// Allocate `n` zeroed, physically contiguous pages (kernel stacks); returns
/// the address of the first, or null.
pub fn physallocContig(n: u64) ?PAddr {
    const pa: PAddr = PAddr.fromInt(bm.allocContig(n) orelse return null);
    const words: [*]u64 = pagePtr(pa);
    @memset(words[0 .. n * param.PAGE_SIZE / 8], 0);
    return pa;
}

/// Free `n` contiguous pages from physallocContig().
pub fn physfreeContig(pa: PAddr, n: u64) void {
    var k: u64 = 0;
    while (k < n) : (k += 1) physfree(pa.add(k * param.PAGE_SIZE));
}

/// Return a page to the allocator. A page that is not currently allocated (a
/// double free) or outside a loaded range is refused and reported, so the
/// mistake can be found instead of corrupting memory.
pub fn physfree(pa: PAddr) void {
    if (!bm.free(pa.int())) {
        if (validPage(pa)) {
            prf.print("physfree: page not allocated (double free?) pa=");
            prf.printHex(pa.int());
            prf.printLine("");
        }
    }
}

/// Number of free pages.
pub fn freeCount() usize {
    return @intCast(bm.freeCount());
}

/// Total physical pages covered by the loaded memory (for sysctl vm.stats).
pub fn totalPages() usize {
    return @intCast(mem_top >> phys.PAGE_SHIFT);
}
