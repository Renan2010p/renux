// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Physical-page bitmap.
//
// A pure, side-effect-free bitmap of the physical pages. Two bits per page:
//
//   present -- the page is part of a usable physical range (a loaded region);
//   free    -- the page is currently on the free pool.
//
// Keeping the state out of the pages themselves -- unlike a free list that
// stores its "next" link in the free pages -- means a stray write to a free
// page can no longer turn a PTE into a bogus link, and freeing an already-free
// page (or a page that was never loaded) is refused instead of corrupting
// anything.
//
// The whole thing is plain arithmetic over byte slices, so it is unit tested on
// the host with `zig test` (see `zig build test`).

/// Page size shift (4 KiB pages).
pub const PAGE_SHIFT: u6 = 12;

/// Page size in bytes.
pub const PAGE_SIZE: u64 = @as(u64, 1) << PAGE_SHIFT;

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) & ~(a - 1);
}

/// A bitmap of physical pages.
pub const Bitmap = struct {
    /// Free bits (bit set == page is free).
    free_bits: []u8,
    /// Present bits (bit set == page is part of a usable range).
    present_bits: []u8,
    /// Physical address of bit zero's page.
    base: u64,
    /// Number of pages the bitmap covers.
    npages: u64,
    /// Number of free pages.
    nfree: u64,
    /// Where to start the next allocation scan.
    hint: u64,

    /// Prepare a bitmap of `npages` pages starting at physical address `base`.
    /// Both bitmaps are cleared: every page starts out neither present nor free.
    pub fn init(free_bits: []u8, present_bits: []u8, base: u64, npages: u64) Bitmap {
        var i: usize = 0;
        while (i < free_bits.len) : (i += 1) {
            free_bits[i] = 0;
        }
        i = 0;
        while (i < present_bits.len) : (i += 1) {
            present_bits[i] = 0;
        }
        const coverable: u64 = @min(@as(u64, free_bits.len), @as(u64, present_bits.len)) * 8;
        const n: u64 = if (npages < coverable) npages else coverable;
        return .{
            .free_bits = free_bits,
            .present_bits = present_bits,
            .base = base,
            .npages = n,
            .nfree = 0,
            // Hand out high addresses first, like the boot loader arranges
            // memory: the very low pages can still hold in-use boot structures
            // that the memory map reports as usable.
            .hint = if (n > 0) n - 1 else 0,
        };
    }

    fn index(self: *const Bitmap, pa: u64) ?u64 {
        if (pa < self.base) {
            return null;
        }
        if (((pa - self.base) & (PAGE_SIZE - 1)) != 0) {
            return null;
        }
        const i: u64 = (pa - self.base) >> PAGE_SHIFT;
        if (i >= self.npages) {
            return null;
        }
        return i;
    }

    fn bit(bits: []const u8, i: u64) bool {
        return (bits[@intCast(i >> 3)] & (@as(u8, 1) << @intCast(i & 7))) != 0;
    }

    fn setBit(bits: []u8, i: u64, v: bool) void {
        const byte: usize = @intCast(i >> 3);
        const mask: u8 = @as(u8, 1) << @intCast(i & 7);
        if (v) {
            bits[byte] |= mask;
        } else {
            bits[byte] &= ~mask;
        }
    }

    fn isFree(self: *const Bitmap, i: u64) bool {
        return bit(self.free_bits, i);
    }

    fn isPresent(self: *const Bitmap, i: u64) bool {
        return bit(self.present_bits, i);
    }

    /// Mark the pages in [start, end) as usable and free.
    pub fn load(self: *Bitmap, start: u64, end: u64) void {
        var pa: u64 = alignUp(start, PAGE_SIZE);
        while (pa + PAGE_SIZE <= end) : (pa += PAGE_SIZE) {
            if (self.index(pa)) |i| {
                if (!self.isPresent(i)) {
                    setBit(self.present_bits, i, true);
                }
                if (!self.isFree(i)) {
                    setBit(self.free_bits, i, true);
                    self.nfree += 1;
                }
            }
        }
    }

    /// Remove the pages in [start, end) from the free pool, so they are never
    /// handed out (used to carve boot-loader modules out of memory the map
    /// still calls usable). They stay present.
    pub fn unload(self: *Bitmap, start: u64, end: u64) void {
        var pa: u64 = alignUp(start, PAGE_SIZE);
        while (pa + PAGE_SIZE <= end) : (pa += PAGE_SIZE) {
            if (self.index(pa)) |i| {
                if (self.isFree(i)) {
                    setBit(self.free_bits, i, false);
                    self.nfree -= 1;
                }
            }
        }
    }

    /// Allocate a free page; returns its physical address, or null when none is
    /// free. Scans downward from the hint (high addresses are handed out first).
    pub fn alloc(self: *Bitmap) ?u64 {
        if (self.nfree == 0) {
            return null;
        }
        var i: u64 = self.hint;
        var scanned: u64 = 0;
        while (scanned < self.npages) : (scanned += 1) {
            if (self.isFree(i)) {
                setBit(self.free_bits, i, false);
                self.nfree -= 1;
                self.hint = if (i == 0) self.npages - 1 else i - 1;
                return self.base + i * PAGE_SIZE;
            }
            i = if (i == 0) self.npages - 1 else i - 1;
        }
        return null;
    }

    /// Allocate `n` physically contiguous free pages (kernel stacks); returns
    /// the address of the first, or null when no such run exists. Scans down
    /// from the top, like alloc().
    pub fn allocContig(self: *Bitmap, n: u64) ?u64 {
        if (n == 0 or self.nfree < n or n > self.npages) {
            return null;
        }
        var i: u64 = self.npages - n + 1;
        while (i > 0) {
            i -= 1;
            var k: u64 = 0;
            while (k < n and self.isFree(i + k)) : (k += 1) {}
            if (k == n) {
                k = 0;
                while (k < n) : (k += 1) setBit(self.free_bits, i + k, false);
                self.nfree -= n;
                return self.base + i * PAGE_SIZE;
            }
        }
        return null;
    }

    /// Free the page at `pa`. Returns false when it is not currently allocated
    /// (a double free) or is outside a loaded range, leaving the bitmap
    /// unchanged so the mistake cannot corrupt anything.
    pub fn free(self: *Bitmap, pa: u64) bool {
        const i: u64 = self.index(pa) orelse return false;
        if (!self.isPresent(i)) {
            return false; // never loaded: not ours to free
        }
        if (self.isFree(i)) {
            return false; // already free: a double free
        }
        setBit(self.free_bits, i, true);
        self.nfree += 1;
        return true;
    }

    /// Number of free pages.
    pub fn freeCount(self: *const Bitmap) u64 {
        return self.nfree;
    }
};

// -- tests (run on the host with `zig build test`) ---------------------------

const testing = @import("std").testing;

/// A bitmap over `n` pages starting at 0x1000, for the tests. Initialised in
/// place so the bitmap's slices point at the harness's own arrays.
const Harness = struct {
    free_bits: [8]u8 = undefined,
    present_bits: [8]u8 = undefined,
    bm: Bitmap = undefined,

    fn init(h: *Harness, n: u64) void {
        h.bm = Bitmap.init(&h.free_bits, &h.present_bits, 0x1000, n);
        h.bm.load(0x1000, 0x1000 + n * PAGE_SIZE);
    }
};

test "load marks pages free and alloc hands them out" {
    var h: Harness = .{};
    h.init(32);
    try testing.expectEqual(@as(u64, 32), h.bm.freeCount());

    // Pages are handed out from the top down.
    const p0 = h.bm.alloc().?;
    try testing.expectEqual(@as(u64, 0x1000 + 31 * PAGE_SIZE), p0);
    try testing.expectEqual(@as(u64, 31), h.bm.freeCount());

    const p1 = h.bm.alloc().?;
    try testing.expectEqual(@as(u64, 0x1000 + 30 * PAGE_SIZE), p1);
}

test "free returns a page to the pool and it becomes allocatable again" {
    var h: Harness = .{};
    h.init(8);
    const a = h.bm.alloc().?;
    const b = h.bm.alloc().?;
    try testing.expectEqual(@as(u64, 6), h.bm.freeCount());

    try testing.expect(h.bm.free(a));
    try testing.expectEqual(@as(u64, 7), h.bm.freeCount());
    try testing.expect(h.bm.free(b));
    try testing.expectEqual(@as(u64, 8), h.bm.freeCount());

    _ = h.bm.alloc().?;
    _ = h.bm.alloc().?;
    try testing.expectEqual(@as(u64, 6), h.bm.freeCount());
}

test "double free is rejected and does not change the count" {
    var h: Harness = .{};
    h.init(8);
    const a = h.bm.alloc().?;
    try testing.expect(h.bm.free(a));
    const after_first = h.bm.freeCount();
    // The second free must be rejected: otherwise the page would be on the free
    // pool twice and could be handed out to two owners.
    try testing.expect(!h.bm.free(a));
    try testing.expectEqual(after_first, h.bm.freeCount());
}

test "free rejects out-of-range, unaligned and never-loaded pages" {
    var h: Harness = .{};
    h.init(8);
    try testing.expect(!h.bm.free(0x1001)); // unaligned
    try testing.expect(!h.bm.free(0x0)); // below base
    try testing.expect(!h.bm.free(0x1000 + 8 * PAGE_SIZE)); // above range
    try testing.expect(!h.bm.free(0x1000 + 100 * PAGE_SIZE));

    var h2: Harness = .{};
    h2.bm = Bitmap.init(&h2.free_bits, &h2.present_bits, 0x1000, 8);
    try testing.expect(!h2.bm.free(0x1000)); // never loaded
}

test "allocation is exhausted and reports it" {
    var h: Harness = .{};
    h.init(8);
    var got: u64 = 0;
    while (h.bm.alloc()) |_| {
        got += 1;
    }
    try testing.expectEqual(@as(u64, 8), got);
    try testing.expectEqual(@as(u64, 0), h.bm.freeCount());
    try testing.expect(h.bm.alloc() == null);
}

test "unload removes pages from the free pool" {
    var h: Harness = .{};
    h.init(8);
    try testing.expectEqual(@as(u64, 8), h.bm.freeCount());
    // Carve out pages 2 and 3 (a module overlapping usable memory).
    h.bm.unload(0x1000 + 2 * PAGE_SIZE, 0x1000 + 4 * PAGE_SIZE);
    try testing.expectEqual(@as(u64, 6), h.bm.freeCount());

    var got: u64 = 0;
    while (h.bm.alloc()) |pa| {
        const off = pa - 0x1000;
        try testing.expect(off < 2 * PAGE_SIZE or off >= 4 * PAGE_SIZE);
        got += 1;
    }
    try testing.expectEqual(@as(u64, 6), got);
}

test "the scan hint wraps and reuses earlier holes" {
    var h: Harness = .{};
    h.init(8);
    const a = h.bm.alloc().?;
    _ = h.bm.alloc().?;
    _ = h.bm.alloc().?;
    // Free the first page; the hint is past it, so the scan must wrap.
    try testing.expect(h.bm.free(a));
    var found = false;
    var n: u64 = 0;
    while (n < 8) : (n += 1) {
        if (h.bm.alloc()) |pa| {
            if (pa == a) {
                found = true;
                break;
            }
        } else {
            break;
        }
    }
    try testing.expect(found);
}

test "allocContig returns a run of adjacent free pages" {
    var h: Harness = .{};
    h.init(16);
    const a: u64 = h.bm.allocContig(4) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 12), h.bm.freeCount());
    // No page of the run is handed out again.
    while (h.bm.alloc()) |pa| {
        try testing.expect(pa < a or pa >= a + 4 * PAGE_SIZE);
    }
}

test "allocContig skips runs broken by an allocated page" {
    var h: Harness = .{};
    h.init(8);
    // Allocate everything, then free pages 0,1 | 3,4,5 | 7: the longest run
    // of free pages is three long, starting at page 3.
    while (h.bm.alloc()) |_| {}
    for ([_]u64{ 0, 1, 3, 4, 5, 7 }) |i| {
        try testing.expect(h.bm.free(0x1000 + i * PAGE_SIZE));
    }
    try testing.expectEqual(@as(?u64, null), h.bm.allocContig(4));
    try testing.expectEqual(@as(?u64, 0x1000 + 3 * PAGE_SIZE), h.bm.allocContig(3));
    try testing.expectEqual(@as(u64, 3), h.bm.freeCount());
}
