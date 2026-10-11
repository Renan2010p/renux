// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Anonymous memory fault registry.
//
// This is a heavily simplified stand-in for NetBSD's sys/uvm/uvm_fault.c. It
// records anonymous virtual address ranges that should be filled on demand:
// when the machine-dependent trap code takes a not-present page fault for an
// address inside a registered range, it allocates a zero page and maps it, then
// lets the faulting instruction retry. There is no object/amap indirection yet.

/// A registered anonymous range [start, end).
pub const Region: type = struct {
    start: u64,
    end: u64,
};

const MAX_REGIONS: usize = 8;

var regions: [MAX_REGIONS]Region = undefined;
var count: usize = 0;

/// Register [start, end) as demand-zero anonymous memory.
pub fn register(start: u64, end: u64) void {
    if (count >= MAX_REGIONS) {
        return;
    }
    regions[count] = .{ .start = start, .end = end };
    count += 1;
}

/// Return the region containing `va`, if any.
pub fn regionFor(va: u64) ?Region {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (va >= regions[i].start and va < regions[i].end) {
            return regions[i];
        }
    }
    return null;
}
