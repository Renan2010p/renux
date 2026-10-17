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

/// Mappings of each page in user address spaces (FreeBSD's wire and object
/// references, reduced to one count): copy-on-write fork shares a page
/// between processes, and the page is freed when its last mapping goes. A
/// page that is not mapped in user space has a count of 0.
var refs: [free_bits.len * 8]u16 = @splat(0);

/// Called when an allocation finds no free page: the buffer cache gives
/// back up to `pages` clean pages (FreeBSD's vm_lowmem event, Linux's
/// shrinkers). Returns how many it freed.
pub var reclaim_hook: ?*const fn (pages: usize) usize = null;

/// Pages asked of the reclaim hook at a time.
const RECLAIM_BATCH: usize = 256;

/// Set while the hook runs: freeing buffers must not reclaim again.
var reclaiming: bool = false;

/// A free page from the bitmap, asking the buffer cache for memory once if
/// there is none.
fn takePage() ?u64 {
    if (bm.alloc()) |pa| return pa;
    const hook = reclaim_hook orelse return null;
    if (reclaiming) return null;
    reclaiming = true;
    defer reclaiming = false;
    if (hook(RECLAIM_BATCH) == 0) return null;
    return bm.alloc();
}

fn pfn(pa: PAddr) usize {
    return @intCast(pa.int() >> phys.PAGE_SHIFT);
}

/// A zeroed page for user space, counted as mapped once.
pub fn allocUser() ?PAddr {
    const pa: PAddr = physalloc() orelse return null;
    refs[pfn(pa)] = 1;
    return pa;
}

/// Like allocUser, but not zeroed: for a copy that overwrites it whole.
pub fn allocUserUninit() ?PAddr {
    const pa: PAddr = physallocUninit() orelse return null;
    refs[pfn(pa)] = 1;
    return pa;
}

/// Count one more user mapping of `pa` (copy-on-write sharing).
pub fn ref(pa: PAddr) void {
    refs[pfn(pa)] += 1;
}

/// Drop one user mapping of `pa`, freeing the page with the last one.
pub fn unref(pa: PAddr) void {
    const n: *u16 = &refs[pfn(pa)];
    if (n.* == 0) {
        prf.print("vm_page: unref of an unmapped page pa=");
        prf.printHex(pa.int());
        prf.printLine("");
        return;
    }
    n.* -= 1;
    if (n.* == 0) physfree(pa);
}

/// The user mappings of `pa`.
pub fn refCount(pa: PAddr) u16 {
    return refs[pfn(pa)];
}

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
    const pa: PAddr = PAddr.fromInt(takePage() orelse return null);
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
    return PAddr.fromInt(takePage() orelse return null);
}

/// Allocate `n` zeroed, physically contiguous pages (kernel stacks); returns
/// the address of the first, or null.
pub fn physallocContig(n: u64) ?PAddr {
    const pa: PAddr = PAddr.fromInt(bm.allocContig(n) orelse blk: {
        // Freed buffers are scattered, but give them back and try again.
        const hook = reclaim_hook orelse return null;
        if (reclaiming) return null;
        reclaiming = true;
        defer reclaiming = false;
        _ = hook(RECLAIM_BATCH);
        break :blk bm.allocContig(n) orelse return null;
    });
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
