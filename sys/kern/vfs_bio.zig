// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Buffer cache.
//
// The Zig counterpart of FreeBSD's sys/kern/vfs_bio.c, reduced to a fixed
// pool of page-sized buffers with the classic interface: bread() returns a
// held buffer with a disk block's contents, getblk() one for a block about
// to be overwritten, brelse() gives it back, bwrite() writes it at once and
// bdwrite() marks it dirty for a later write. Unused buffers are recycled
// least recently used first, writing them out if dirty.
//
// Delayed writes reach the disk when a filesystem syncs (sync(2), fsync(2),
// unmount, reboot) and from the syncer, which the scheduler runs when the
// CPU is idle: a dirty buffer is written once it has waited SYNCDELAY ticks,
// as FreeBSD's syncer daemon does every few seconds.

const geom_disk: type = @import("../geom/geom_disk.zig");
const arch: type = @import("../arch/arch.zig");
const errno: type = @import("../sys/errno.zig");
const param: type = @import("../sys/param.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const prf: type = @import("subr_prf.zig");

/// Number of buffers (4 MiB of cache with 4 KiB pages).
const NBUF: usize = 1024;

/// Largest block a buffer holds.
pub const MAXBSIZE: u32 = @intCast(param.PAGE_SIZE);

/// Ticks a dirty buffer may wait before the syncer writes it (3 s at 100 Hz).
const SYNCDELAY: u64 = 300;

pub const Buf: type = struct {
    b_disk: ?*geom_disk.Disk = null,
    /// Byte offset of the block on the disk, and its size.
    b_offset: u64 = 0,
    b_bcount: u32 = 0,
    b_data: [*]u8 = undefined,
    /// The contents match the disk (or are newer).
    b_valid: bool = false,
    /// The contents are newer than the disk.
    b_dirty: bool = false,
    /// Tick at which the buffer became dirty.
    b_dirtied: u64 = 0,
    /// Holders (bread/getblk without the matching release).
    b_refcnt: u32 = 0,
    /// Last use, for LRU recycling.
    b_lru: u64 = 0,
};

var bufs: [NBUF]Buf = undefined;
var nbuf: usize = 0;
var lru_clock: u64 = 0;
var ndirty: usize = 0;

/// The clock's tick count, for write ageing.
fn now() u64 {
    return arch.clock.tickCount();
}

fn find(dp: *geom_disk.Disk, offset: u64) ?*Buf {
    for (bufs[0..nbuf]) |*bp| {
        if (bp.b_disk == dp and bp.b_offset == offset and bp.b_valid) return bp;
    }
    return null;
}

/// Write `bp` to its disk now.
fn writeOut(bp: *Buf) i32 {
    const dp: *geom_disk.Disk = bp.b_disk orelse return errno.EIO;
    const e: i32 = dp.d_strategy(dp, true, bp.b_offset, bp.b_data[0..bp.b_bcount]);
    if (e == 0 and bp.b_dirty) {
        bp.b_dirty = false;
        ndirty -= 1;
    }
    return e;
}

/// A buffer to reuse: a fresh one while the pool grows, else the least
/// recently used one nobody holds (written out first when dirty).
fn getNewBuf() ?*Buf {
    if (nbuf < NBUF) {
        const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;
        const pa: u64 = vm_page.physalloc() orelse return null;
        bufs[nbuf] = .{ .b_data = @ptrFromInt(pa + hhdm) };
        nbuf += 1;
        return &bufs[nbuf - 1];
    }
    var victim: ?*Buf = null;
    for (bufs[0..nbuf]) |*bp| {
        if (bp.b_refcnt != 0) continue;
        if (victim == null or bp.b_lru < victim.?.b_lru) victim = bp;
    }
    const bp: *Buf = victim orelse return null;
    if (bp.b_dirty) {
        if (writeOut(bp) != 0) prf.log(prf.LOG_ERR, "vfs_bio: write error while recycling a buffer", .{});
    }
    bp.b_valid = false;
    return bp;
}

/// The buffer for `size` bytes at `offset` on `dp`, held, without reading
/// it (for a block that will be overwritten whole). Its data is whatever the
/// cache had, or zeroes for a new buffer.
pub fn getblk(dp: *geom_disk.Disk, offset: u64, size: u32) ?*Buf {
    if (size > MAXBSIZE) return null;
    lru_clock += 1;
    if (find(dp, offset)) |bp| {
        bp.b_refcnt += 1;
        bp.b_lru = lru_clock;
        return bp;
    }
    const bp: *Buf = getNewBuf() orelse return null;
    bp.b_disk = dp;
    bp.b_offset = offset;
    bp.b_bcount = size;
    bp.b_refcnt = 1;
    bp.b_lru = lru_clock;
    bp.b_dirty = false;
    @memset(bp.b_data[0..size], 0);
    bp.b_valid = true;
    return bp;
}

/// The buffer for `size` bytes at `offset` on `dp`, held, with the disk's
/// contents. Returns null on an I/O error.
pub fn bread(dp: *geom_disk.Disk, offset: u64, size: u32) ?*Buf {
    if (find(dp, offset)) |bp| {
        lru_clock += 1;
        bp.b_refcnt += 1;
        bp.b_lru = lru_clock;
        return bp;
    }
    const bp: *Buf = getblk(dp, offset, size) orelse return null;
    if (dp.d_strategy(dp, false, offset, bp.b_data[0..size]) != 0) {
        bp.b_valid = false;
        bp.b_refcnt = 0;
        return null;
    }
    return bp;
}

/// Give back a held buffer, unchanged.
pub fn brelse(bp: *Buf) void {
    if (bp.b_refcnt > 0) bp.b_refcnt -= 1;
}

/// Mark a held buffer dirty and give it back; it is written later.
pub fn bdwrite(bp: *Buf) void {
    if (!bp.b_dirty) {
        bp.b_dirty = true;
        bp.b_dirtied = now();
        ndirty += 1;
    }
    brelse(bp);
}

/// Write a held buffer now and give it back. Returns 0 or an errno.
pub fn bwrite(bp: *Buf) i32 {
    if (!bp.b_dirty) {
        bp.b_dirty = true;
        ndirty += 1;
    }
    const e: i32 = writeOut(bp);
    brelse(bp);
    return e;
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
        bp.b_valid = false;
        bp.b_disk = null;
        bp.b_refcnt = 0;
    }
}

/// The syncer: write the dirty buffers that have waited SYNCDELAY ticks.
/// `busy` reports whether a buffer's owner (a filesystem in the middle of
/// an update) must be left alone for now. Called by the scheduler when
/// nothing is runnable.
pub fn syncer(busy: *const fn (dp: *geom_disk.Disk) bool) void {
    if (ndirty == 0) return;
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
