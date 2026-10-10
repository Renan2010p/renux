// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
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

/// Prepare the allocator with the direct-map offset used to reach memory.
pub fn init(offset: u64) void {
    hhdm = offset;
    head = 0;
    count = 0;
}

/// Address of the free-list link stored in a free page.
fn link(pa: u64) *u64 {
    return @ptrFromInt(pa + hhdm);
}

/// Add the pages in [start, end) to the free list.
pub fn physload(start: u64, end: u64) void {
    var pa: u64 = param.alignUp(start, param.PAGE_SIZE);
    while (pa + param.PAGE_SIZE <= end) : (pa += param.PAGE_SIZE) {
        if (pa == 0) {
            continue; // never hand out page 0
        }
        const node = link(pa);
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
    const pa: u64 = head;
    head = link(pa).*;
    count -= 1;

    const page: [*]u64 = @ptrFromInt(pa + hhdm);
    var i: usize = 0;
    while (i < param.PAGE_SIZE / 8) : (i += 1) {
        page[i] = 0;
    }
    return pa;
}

/// Return a page to the free list.
pub fn physfree(pa: u64) void {
    const node = link(pa);
    node.* = head;
    head = pa;
    count += 1;
}

/// Number of free pages.
pub fn freeCount() usize {
    return count;
}
