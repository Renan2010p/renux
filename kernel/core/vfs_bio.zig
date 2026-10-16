// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Buffer cache.
//
// The Zig counterpart of FreeBSD's sys/kern/vfs_bio.c: a pool of page-sized
// buffers with the classic interface: bread() returns a held buffer with a
// disk block's contents, getblk() one for a block about to be overwritten,
// brelse() gives it back, bwrite() writes it at once and bdwrite() marks it
// dirty for a later write.
//
// Like the BSD buffer cache and Linux's page cache, it is sized from memory
// and every lookup is O(1):
//
//   - the pool holds up to a quarter of physical memory (at most
//     NBUF_MAX buffers), growing a buffer at a time as blocks are read;
//   - a hash table on (disk, offset) finds a cached block without scanning
//     the pool (FreeBSD's bufhash);
//   - a least-recently-used list orders the buffers, so the one to recycle
//     is at its head, written out first when dirty (FreeBSD's free queues).
//
// A caller never sees a *Buf. It holds a `Held(access)` handle instead, which
// owns the reference for as long as it lives and gives it back with
// release(). The handle is the buffer's borrow: the compiler keeps a read
// handle from marking the buffer dirty (only Held(.write) offers markDirty),
// and the runtime catches a buffer used or released twice. Get the handle
// with bread (contents), breadMut (contents, for change) or getblk (to be
// overwritten whole), and always give it back:
//
//     var b = vfs_bio.bread(dp, off, size) orelse return error.Io;
//     defer b.release();
//     ... b.data() ...
//
// Delayed writes reach the disk when a filesystem syncs (sync(2), fsync(2),
// unmount, reboot) and from the syncer, which the scheduler runs when the
// CPU is idle: a dirty buffer is written once it has waited SYNCDELAY ticks,
// as FreeBSD's syncer daemon does every few seconds.

const std: type = @import("std");
const geom_disk: type = @import("../geom/geom_disk.zig");
const arch: type = @import("../arch/arch.zig");
const errno: type = @import("../sys/errno.zig");
const param: type = @import("../sys/param.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const prf: type = @import("subr_prf.zig");
const vm_init: type = @import("../vm/vm_init.zig");

/// The most buffers the pool may grow to (512 MiB of cache with 4 KiB
/// pages); the actual limit is a quarter of memory (`poolLimit`).
const NBUF_MAX: usize = 131072;

/// Buckets of the hash table (a power of two).
const HASH_SIZE: usize = 65536;

/// "No buffer", in the index-based links below.
const NONE: u32 = std.math.maxInt(u32);

/// Largest block a buffer holds.
pub const MAXBSIZE: u32 = @intCast(param.PAGE_SIZE);

/// Ticks a dirty buffer may wait before the syncer writes it (3 s at 100 Hz).
const SYNCDELAY: u64 = 300;

/// A buffer of the pool. Private: callers hold a `Held(access)` handle, never
/// a raw pointer.
const Buf: type = struct {
    b_disk: ?*geom_disk.Disk = null,
    /// Byte offset of the block on the disk, and its size.
    b_offset: u64 = 0,
    b_bcount: u32 = 0,
    /// The page the buffer lives in, reached through the direct map.
    b_data: vm_page.KAddr = vm_page.KAddr.fromInt(0),
    /// The contents match the disk (or are newer).
    b_valid: bool = false,
    /// The contents are newer than the disk.
    b_dirty: bool = false,
    /// Tick at which the buffer became dirty.
    b_dirtied: u64 = 0,
    /// Holders (bread/getblk without the matching release).
    b_refcnt: u32 = 0,
    /// The next buffer in this one's hash bucket (valid buffers only).
    hash_next: u32 = NONE,
    /// Neighbours in the LRU list: `lru_prev` was used less recently.
    lru_prev: u32 = NONE,
    lru_next: u32 = NONE,
};

/// What a handle lets its holder do with the buffer's bytes. `read` gives a
/// `[]const u8` and no markDirty(); `write` gives a `[]u8` and both. The
/// distinction is checked at compile time.
pub const Access: type = enum { read, write };

/// The byte slice a handle of the given access exposes.
pub fn Data(comptime access: Access) type {
    return switch (access) {
        .read => []const u8,
        .write => []u8,
    };
}

/// A held buffer: the caller's borrow of a `Buf`, and the only way to reach
/// its bytes. Release it when done (usually `defer h.release()`); a handle is
/// released exactly once.
pub fn Held(comptime access: Access) type {
    return struct {
        buf: *Buf,
        /// Set once the buffer has been given back. A handle used after that
        /// is a bug, and is reported rather than corrupting a recycled buffer.
        released: bool = false,

        const Self = @This();

        /// Byte offset of the block on the disk.
        pub inline fn offset(self: Self) u64 {
            return self.buf.b_offset;
        }

        /// Size of the block in bytes.
        pub inline fn size(self: Self) u32 {
            return self.buf.b_bcount;
        }

        /// The buffer's bytes. A read handle yields a `[]const u8`; a write
        /// handle a `[]u8`.
        pub fn data(self: Self) Data(access) {
            if (self.released) {
                prf.log(prf.LOG_ERR, "vfs_bio: use of a released buffer at offset %llu", .{self.buf.b_offset});
            }
            return self.buf.b_data.manyPtr(u8)[0..self.buf.b_bcount];
        }

        /// Mark the buffer dirty; the syncer writes it out later. Only a
        /// write handle may do this, so changing a buffer borrowed for
        /// reading is a compile error.
        pub fn markDirty(self: *Self) void {
            if (access == .read) @compileError("markDirty on a buffer held for reading (use breadMut/getblk)");
            if (!self.buf.b_dirty) {
                self.buf.b_dirty = true;
                self.buf.b_dirtied = now();
                ndirty += 1;
            }
        }

        /// Write the buffer now and give it back. Returns 0 or an errno.
        pub fn write(self: *Self) i32 {
            if (access == .read) @compileError("write on a buffer held for reading (use breadMut/getblk)");
            if (!self.buf.b_dirty) {
                self.buf.b_dirty = true;
                ndirty += 1;
            }
            const e: i32 = writeOut(self.buf);
            self.release();
            return e;
        }

        /// Give the buffer back. Safe to call once; a second call, or a hold
        /// that was never counted, is reported and ignored rather than
        /// corrupting the reference count.
        pub fn release(self: *Self) void {
            if (self.released) {
                prf.log(prf.LOG_ERR, "vfs_bio: buffer released twice at offset %llu", .{self.buf.b_offset});
                return;
            }
            self.released = true;
            if (self.buf.b_refcnt == 0) {
                prf.log(prf.LOG_ERR, "vfs_bio: buffer released with no hold at offset %llu", .{self.buf.b_offset});
                return;
            }
            self.buf.b_refcnt -= 1;
        }
    };
}

var bufs: [NBUF_MAX]Buf = undefined;
var nbuf: usize = 0;
var ndirty: usize = 0;
/// Heads of the hash buckets.
var hash: [HASH_SIZE]u32 = @splat(NONE);
/// The LRU list: `lru_head` is the least recently used buffer.
var lru_head: u32 = NONE;
var lru_tail: u32 = NONE;
/// The pool's size limit, computed on first use (0: not yet).
var pool_limit: usize = 0;
/// Tick of the syncer's last pass.
var last_sync: u64 = 0;

/// The most buffers the pool may hold: a quarter of physical memory, at
/// least 1024 buffers, at most NBUF_MAX.
fn poolLimit() usize {
    if (pool_limit == 0) {
        const pages: u64 = vm_init.physmem() / param.PAGE_SIZE;
        pool_limit = @intCast(std.math.clamp(pages / 4, 1024, NBUF_MAX));
    }
    return pool_limit;
}

fn indexOf(bp: *const Buf) u32 {
    return @intCast(bp - &bufs[0]);
}

// -- the hash table --------------------------------------------------------------

/// The bucket of the block at `offset` on `dp`.
fn bucket(dp: *const geom_disk.Disk, offset: u64) usize {
    const key: u64 = (offset / 512) ^ (@as(u64, @intFromPtr(dp)) >> 4);
    // Fibonacci hashing spreads consecutive blocks over the table.
    return @intCast((key *% 0x9e37_79b9_7f4a_7c15) >> (64 - @ctz(@as(u64, HASH_SIZE))));
}

fn hashInsert(bp: *Buf) void {
    const head: *u32 = &hash[bucket(bp.b_disk.?, bp.b_offset)];
    bp.hash_next = head.*;
    head.* = indexOf(bp);
}

fn hashRemove(bp: *Buf) void {
    var link: *u32 = &hash[bucket(bp.b_disk.?, bp.b_offset)];
    const index: u32 = indexOf(bp);
    while (link.* != NONE) : (link = &bufs[link.*].hash_next) {
        if (link.* == index) {
            link.* = bp.hash_next;
            bp.hash_next = NONE;
            return;
        }
    }
}

// -- the LRU list ----------------------------------------------------------------

fn lruRemove(bp: *Buf) void {
    if (bp.lru_prev != NONE) bufs[bp.lru_prev].lru_next = bp.lru_next else lru_head = bp.lru_next;
    if (bp.lru_next != NONE) bufs[bp.lru_next].lru_prev = bp.lru_prev else lru_tail = bp.lru_prev;
    bp.lru_prev = NONE;
    bp.lru_next = NONE;
}

/// Put `bp` at the tail of the list: the most recently used.
fn lruAppend(bp: *Buf) void {
    const index: u32 = indexOf(bp);
    bp.lru_prev = lru_tail;
    bp.lru_next = NONE;
    if (lru_tail != NONE) bufs[lru_tail].lru_next = index else lru_head = index;
    lru_tail = index;
}

/// Mark `bp` as just used.
fn touch(bp: *Buf) void {
    lruRemove(bp);
    lruAppend(bp);
}

/// The clock's tick count, for write ageing.
fn now() u64 {
    return arch.clock.tickCount();
}

/// The cached buffer for the block at `offset` on `dp`, or null.
fn find(dp: *geom_disk.Disk, offset: u64) ?*Buf {
    var index: u32 = hash[bucket(dp, offset)];
    while (index != NONE) : (index = bufs[index].hash_next) {
        const bp: *Buf = &bufs[index];
        if (bp.b_disk == dp and bp.b_offset == offset) return bp;
    }
    return null;
}

/// Write `bp` to its disk now.
fn writeOut(bp: *Buf) i32 {
    const dp: *geom_disk.Disk = bp.b_disk orelse return errno.EIO;
    const e: i32 = dp.d_strategy(dp, true, bp.b_offset, bp.b_data.manyPtr(u8)[0..bp.b_bcount]);
    if (e == 0 and bp.b_dirty) {
        bp.b_dirty = false;
        ndirty -= 1;
    }
    return e;
}

/// A buffer to reuse: a fresh one while the pool may grow (and memory is
/// left), else the least recently used one nobody holds, written out first
/// when dirty. The buffer returned is in no hash bucket and at the tail of
/// the LRU list.
fn getNewBuf() ?*Buf {
    if (nbuf < poolLimit()) grow: {
        const hhdm: u64 = arch.boot.hhdmOffset() orelse break :grow;
        const pa: vm_page.PAddr = vm_page.physalloc() orelse break :grow;
        bufs[nbuf] = .{ .b_data = pa.toKern(hhdm) };
        nbuf += 1;
        const bp: *Buf = &bufs[nbuf - 1];
        lruAppend(bp);
        return bp;
    }
    var index: u32 = lru_head;
    while (index != NONE) : (index = bufs[index].lru_next) {
        const bp: *Buf = &bufs[index];
        if (bp.b_refcnt != 0) continue;
        if (bp.b_dirty) {
            if (writeOut(bp) != 0) prf.log(prf.LOG_ERR, "vfs_bio: write error while recycling a buffer", .{});
        }
        if (bp.b_valid) hashRemove(bp);
        bp.b_valid = false;
        touch(bp);
        return bp;
    }
    return null;
}

/// Take a held buffer for `size` bytes at `offset` on `dp`. `read` reads the
/// block from the disk; otherwise the caller will overwrite it whole and the
/// contents are zeroed instead.
fn hold(dp: *geom_disk.Disk, offset: u64, size: u32, read: bool) ?*Buf {
    if (size > MAXBSIZE) return null;
    if (find(dp, offset)) |bp| {
        bp.b_refcnt += 1;
        touch(bp);
        return bp;
    }
    const bp: *Buf = getNewBuf() orelse return null;
    bp.b_disk = dp;
    bp.b_offset = offset;
    bp.b_bcount = size;
    bp.b_refcnt = 1;
    bp.b_dirty = false;
    if (read) {
        if (dp.d_strategy(dp, false, offset, bp.b_data.manyPtr(u8)[0..size]) != 0) {
            bp.b_valid = false;
            bp.b_refcnt = 0;
            return null;
        }
    } else {
        @memset(bp.b_data.manyPtr(u8)[0..size], 0);
    }
    bp.b_valid = true;
    hashInsert(bp);
    return bp;
}

/// Read `size` bytes at `offset` on `dp` and hold them for reading. Returns
/// null on an I/O error.
pub fn bread(dp: *geom_disk.Disk, offset: u64, size: u32) ?Held(.read) {
    const bp: *Buf = hold(dp, offset, size, true) orelse return null;
    return .{ .buf = bp };
}

/// Read `size` bytes at `offset` and hold them for change as well: the caller
/// may modify the block and mark it dirty.
pub fn breadMut(dp: *geom_disk.Disk, offset: u64, size: u32) ?Held(.write) {
    const bp: *Buf = hold(dp, offset, size, true) orelse return null;
    return .{ .buf = bp };
}

/// The buffer for `size` bytes at `offset` on `dp`, held for change, without
/// reading it (for a block that will be overwritten whole). Its data is
/// zeroes for a new buffer.
pub fn getblk(dp: *geom_disk.Disk, offset: u64, size: u32) ?Held(.write) {
    const bp: *Buf = hold(dp, offset, size, false) orelse return null;
    return .{ .buf = bp };
}

/// Write every dirty buffer of `dp` (all disks when null) and flush the
/// disks' caches. Returns the first error.
pub fn bflush(dp: ?*geom_disk.Disk) i32 {
    var err: i32 = 0;
    for (bufs[0..nbuf]) |*bp| {
        if (!bp.b_dirty) continue;
        if (dp != null and bp.b_disk != dp) continue;
        const e: i32 = writeOut(bp);
        if (e != 0 and err == 0) err = e;
    }
    for (geom_disk.list()) |d| {
        if (dp != null and d != dp) continue;
        if (d.d_flush) |f| {
            const e: i32 = f(d);
            if (e != 0 and err == 0) err = e;
        }
    }
    return err;
}

/// Buffers waiting to be written.
pub fn dirtyCount() usize {
    return ndirty;
}

/// Forget every buffer of `dp` (after its filesystem is unmounted and
/// flushed).
pub fn binval(dp: *geom_disk.Disk) void {
    for (bufs[0..nbuf]) |*bp| {
        if (bp.b_disk != dp) continue;
        if (bp.b_dirty) {
            bp.b_dirty = false;
            ndirty -= 1;
        }
        if (bp.b_valid) hashRemove(bp);
        bp.b_valid = false;
        bp.b_disk = null;
        bp.b_refcnt = 0;
    }
}

/// The syncer: write the dirty buffers that have waited SYNCDELAY ticks.
/// `busy` reports whether a buffer's owner (a filesystem in the middle of
/// an update) must be left alone for now. Called by the scheduler when
/// nothing is runnable; like FreeBSD's syncer daemon, it makes a pass at
/// most once a second.
pub fn syncer(busy: *const fn (dp: *geom_disk.Disk) bool) void {
    if (ndirty == 0) return;
    if (now() - last_sync < arch.clock.HZ) return;
    last_sync = now();
    var flushed: [8]?*geom_disk.Disk = @splat(null);
    var nflushed: usize = 0;
    for (bufs[0..nbuf]) |*bp| {
        if (!bp.b_dirty or now() - bp.b_dirtied < SYNCDELAY) continue;
        const dp: *geom_disk.Disk = bp.b_disk orelse continue;
        if (busy(dp)) continue;
        _ = writeOut(bp);
        var seen: bool = false;
        for (flushed[0..nflushed]) |f| {
            if (f == dp) seen = true;
        }
        if (!seen and nflushed < flushed.len) {
            flushed[nflushed] = dp;
            nflushed += 1;
        }
    }
    for (flushed[0..nflushed]) |f| {
        const d: *geom_disk.Disk = f.?;
        if (d.d_flush) |fl| _ = fl(d);
    }
}
