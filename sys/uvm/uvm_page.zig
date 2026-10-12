// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Physical page allocator.
//
// This is the Zig counterpart of NetBSD's sys/uvm/uvm_page.c, simplified: it
// manages a single free list of 4 KiB pages. Free pages carry the next link in
// their own first 8 bytes, so the allocator needs no side tables; pages are
// reached through the higher-half direct map (HHDM) offset reported by the
// bootloader. Physical page 0 is never handed out and doubles as the "null"
// link, so a list head of 0 means empty.

const param: type = @import("../sys/param.zig");

var hhdm: u64 = 0;
var head: u64 = 0;
var count: usize = 0;
/// One past the highest usable physical address seen by physload.
var mem_top: u64 = 0;

/// One bit per 4 KiB page (up to 4 GiB), set while the page is allocated. It
/// makes physfree() idempotent: freeing an already-free page would put the same
/// page on the free list twice and corrupt it.
var alloc_bits: [131072]u8 = undefined;

/// Page index of `pa` within the allocation bitmap, or null when out of range.
fn bitIndex(pa: u64) ?usize {
    const i: u64 = pa >> 12;
    if (i >= @as(u64, alloc_bits.len) * 8) {
        return null;
    }
    return @intCast(i);
}

/// True when `pa` names an aligned 4 KiB page within the usable physical memory.
pub fn validPage(pa: u64) bool {
    return pa != 0 and (pa & (param.PAGE_SIZE - 1)) == 0 and
        mem_top >= param.PAGE_SIZE and pa <= mem_top - param.PAGE_SIZE;
}

/// Prepare the allocator with the direct-map offset used to reach memory.
pub fn init(offset: u64) void {
    hhdm = offset;
    head = 0;
    count = 0;
    var i: usize = 0;
    while (i < alloc_bits.len) : (i += 1) {
        alloc_bits[i] = 0;
    }
}

/// Address of the free-list link stored in a free page.
fn link(pa: u64) *u64 {
    return @ptrFromInt(pa + hhdm);
}

/// Add the pages in [start, end) to the free list.
pub fn physload(start: u64, end: u64) void {
    if (end > mem_top) {
        mem_top = end;
    }
    var pa: u64 = param.alignUp(start, param.PAGE_SIZE);
    while (pa + param.PAGE_SIZE <= end) : (pa += param.PAGE_SIZE) {
        if (pa == 0) {
            continue; // never hand out page 0
        }
        const node: *u64 = link(pa);
        node.* = head;
        head = pa;
        count += 1;
    }
}

/// Allocate a zeroed 4 KiB page, or null when memory is exhausted.
pub fn physalloc() ?u64 {
    if (head == 0) {
        return null;
    }
    if (!validPage(head)) {
        // A corrupted free list must never be followed into the void.
        head = 0;
        count = 0;
        return null;
    }
    const pa: u64 = head;
    head = link(pa).*;
    count -= 1;
    if (bitIndex(pa)) |i| {
        alloc_bits[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
    }

    const page: [*]u64 = @ptrFromInt(pa + hhdm);
    var i: usize = 0;
    while (i < param.PAGE_SIZE / 8) : (i += 1) {
        page[i] = 0;
    }
    return pa;
}

/// Return a page to the free list.
pub fn physfree(pa: u64) void {
    if (!validPage(pa)) {
        return; // ignore stray/invalid frames rather than corrupt the list
    }
    if (bitIndex(pa)) |i| {
        const mask: u8 = @as(u8, 1) << @intCast(i & 7);
        if ((alloc_bits[i >> 3] & mask) == 0) {
            return; // already free: freeing twice would corrupt the list
        }
        alloc_bits[i >> 3] &= ~mask;
    }
    const node: *u64 = link(pa);
    node.* = head;
    head = pa;
    count += 1;
}

/// Remove the pages in [start, end) from the free list. Used to carve the
/// boot loader's modules out of memory the memory map still calls usable.
pub fn physunload(start: u64, end: u64) void {
    var prev: *u64 = &head;
    while (prev.* != 0) {
        const pa: u64 = prev.*;
        if (pa >= start and pa < end) {
            const node: *u64 = link(pa);
            prev.* = node.*;
            count -= 1;
        } else {
            prev = link(pa);
        }
    }
}

/// Number of free pages.
pub fn freeCount() usize {
    return count;
}
