// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ext2fs filesystem: on-disk format and the operations on it.
//
// This is the Zig counterpart of FreeBSD's sys/fs/ext2fs (ext2fs.h, the
// allocator in ext2_alloc.c, block mapping in ext2_bmap.c and
// ext2_balloc.c, directories in ext2_lookup.c, ext2_inode.c's truncation
// and the inode I/O of ext2_vfsops.c), for the classic ext2 layout: block
// and inode bitmaps per group, direct and single/double/triple indirect
// block pointers, and linear directories.
//
// A filesystem lives either on a disk, reached through the buffer cache
// (core/vfs_bio.zig), or in memory as a boot image (read-only), which is
// how the root image is unpacked at boot.

const vnode: type = @import("../../sys/vnode.zig");
const geom_disk: type = @import("../../geom/geom_disk.zig");
const vfs_bio: type = @import("../../core/vfs_bio.zig");
const kern_sx: type = @import("../../core/kern_sx.zig");

/// Superblock magic (EXT2_SUPER_MAGIC).
pub const SUPER_MAGIC: u16 = 0xEF53;

/// Byte offset of the superblock within the filesystem, and its size.
const SUPER_OFFSET: u64 = 1024;
const SUPER_SIZE: usize = 1024;

/// The root directory's inode number (EXT2_ROOT_INO).
pub const ROOT_INO: u64 = 2;

/// The first ordinary inode of a revision 0 filesystem.
const GOOD_OLD_FIRST_INO: u64 = 11;

/// Size of an inode on disk when the superblock does not give one (ext2fs rev 0).
const DEFAULT_INODE_SIZE: u64 = 128;

/// Bytes of a group descriptor (without the 64bit feature).
const GD_SIZE: u64 = 32;

/// Number of vnodes cached per mount, keyed by inode number.
pub const CACHE_N: usize = 2048;

/// Superblock states.
pub const EXT2_VALID_FS: u16 = 1;
pub const EXT2_ERROR_FS: u16 = 2;

/// Features (s_feature_*).
pub const EXT2F_COMPAT_DIRHASHINDEX: u32 = 0x0020;
pub const EXT2F_INCOMPAT_FTYPE: u32 = 0x0002;
pub const EXT2F_INCOMPAT_RECOVER: u32 = 0x0004;
pub const EXT2F_INCOMPAT_FLEX_BG: u32 = 0x0200;
pub const EXT2F_ROCOMPAT_SPARSESUPER: u32 = 0x0001;
pub const EXT2F_ROCOMPAT_LARGEFILE: u32 = 0x0002;

/// Features this implementation reads and writes.
const INCOMPAT_SUPP: u32 = EXT2F_INCOMPAT_FTYPE | EXT2F_INCOMPAT_FLEX_BG;
const ROCOMPAT_SUPP: u32 = EXT2F_ROCOMPAT_SPARSESUPER | EXT2F_ROCOMPAT_LARGEFILE;

/// Inode flags.
const EXT2_INDEX_FL: u32 = 0x00001000;

/// File-type bits (S_IFMT and friends).
pub const S_IFMT: u16 = 0xF000;
pub const S_IFSOCK: u16 = 0xC000;
pub const S_IFLNK: u16 = 0xA000;
pub const S_IFREG: u16 = 0x8000;
pub const S_IFBLK: u16 = 0x6000;
pub const S_IFDIR: u16 = 0x4000;
pub const S_IFCHR: u16 = 0x2000;
pub const S_IFIFO: u16 = 0x1000;

/// Directory file-type values (the i_file_type byte of a dirent).
pub const FT_UNKNOWN: u8 = 0;
pub const FT_REG: u8 = 1;
pub const FT_DIR: u8 = 2;
pub const FT_CHR: u8 = 3;
pub const FT_BLK: u8 = 4;
pub const FT_FIFO: u8 = 5;
pub const FT_SOCK: u8 = 6;
pub const FT_LNK: u8 = 7;

/// Symbolic links shorter than this live in the block pointer array.
pub const MAXSYMLINKLEN: u64 = 60;

/// What can go wrong while changing the filesystem.
pub const Error: type = error{ NoSpace, Io, TooBig, ReadOnly };

/// Arguments handed to the mount routine: a disk, or an in-memory image.
pub const Args = struct {
    disk: ?*geom_disk.Disk = null,
    image: []const u8 = &.{},
    readonly: bool = false,
};

/// A cached vnode, keyed by inode number.
pub const CacheEntry = struct {
    ino: u64,
    vp: *vnode.Vnode,
    /// Open files on it; an unlinked inode is freed once this drops to 0.
    opens: u32 = 0,
    orphan: bool = false,
};

/// Per-mount state (FreeBSD's struct m_ext2fs with its ext2mount).
pub const Ext2Mount = struct {
    /// The backing store: a disk, or a whole image in memory.
    disk: ?*geom_disk.Disk = null,
    image: []u8 = &.{},
    readonly: bool = true,
    /// Block size in bytes (1024, 2048 or 4096).
    block_size: u64 = 1024,
    blocks_count: u64 = 0,
    inodes_count: u64 = 0,
    blocks_per_group: u64 = 0,
    inodes_per_group: u64 = 0,
    /// Inode size in bytes (128 or 256).
    inode_size: u64 = DEFAULT_INODE_SIZE,
    /// First data block (1 for 1024-byte blocks, else 0).
    first_data_block: u64 = 0,
    first_ino: u64 = GOOD_OLD_FIRST_INO,
    ngroups: u64 = 0,
    rev: u32 = 0,
    feature_incompat: u32 = 0,
    /// The superblock as read, kept up to date (free counts, state) and
    /// written back by writeSuper().
    sb: [SUPER_SIZE]u8 = undefined,
    sb_dirty: bool = false,
    /// Serialises every operation on the filesystem.
    lock: kern_sx.Sx = .{ .name = "ext2fs" },
    /// Vnode cache.
    cache: [*]CacheEntry = undefined,
    ncache: usize = 0,
};

/// A parsed inode (FreeBSD's struct inode, the on-disk part).
pub const Inode = struct {
    mode: u16 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    nlink: u32 = 0,
    atime: i64 = 0,
    mtime: i64 = 0,
    ctime: i64 = 0,
    dtime: i64 = 0,
    /// Space used, in 512-byte sectors.
    blocks: u64 = 0,
    flags: u32 = 0,
    /// The fifteen block pointers (twelve direct, then single, double and
    /// triple indirect). For a short symbolic link the target lives here.
    block: [15]u32 = @splat(0),
};

// -- little-endian access ----------------------------------------------------------

pub fn rd16(b: []const u8, off: u64) u16 {
    if (off + 2 > b.len) return 0;
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}

pub fn rd32(b: []const u8, off: u64) u32 {
    if (off + 4 > b.len) return 0;
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8) |
        (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
}

pub fn wr16(b: []u8, off: u64, v: u16) void {
    if (off + 2 > b.len) return;
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
}

pub fn wr32(b: []u8, off: u64, v: u32) void {
    if (off + 4 > b.len) return;
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
    b[off + 2] = @truncate(v >> 16);
    b[off + 3] = @truncate(v >> 24);
}

// -- block access ------------------------------------------------------------------

/// A filesystem block held for reading or changing.
pub const Blk = struct {
    data: []u8,
    bp: ?*vfs_bio.Buf,
};

/// Read block `bno`. Null on an I/O error or a block past the end.
pub fn bget(mnt: *Ext2Mount, bno: u64) ?Blk {
    const bs: u64 = mnt.block_size;
    if (mnt.disk) |dp| {
        if (bno >= mnt.blocks_count and mnt.blocks_count != 0) return null;
        const bp: *vfs_bio.Buf = vfs_bio.bread(dp, bno * bs, @intCast(bs)) orelse return null;
        return .{ .data = bp.b_data[0..@intCast(bs)], .bp = bp };
    }
    const off: u64 = bno * bs;
    if (off + bs > mnt.image.len) return null;
    return .{ .data = mnt.image[@intCast(off)..@intCast(off + bs)], .bp = null };
}

/// Block `bno` about to be overwritten whole: not read, zero-filled.
fn bnew(mnt: *Ext2Mount, bno: u64) ?Blk {
    const dp: *geom_disk.Disk = mnt.disk orelse return null;
    const bs: u64 = mnt.block_size;
    const bp: *vfs_bio.Buf = vfs_bio.getblk(dp, bno * bs, @intCast(bs)) orelse return null;
    @memset(bp.b_data[0..@intCast(bs)], 0);
    return .{ .data = bp.b_data[0..@intCast(bs)], .bp = bp };
}

/// Release a block unchanged.
pub fn brelse(b: Blk) void {
    if (b.bp) |bp| vfs_bio.brelse(bp);
}

/// Release a changed block; it reaches the disk later (delayed write).
fn bdirty(b: Blk) void {
    if (b.bp) |bp| vfs_bio.bdwrite(bp);
}

// -- mount -------------------------------------------------------------------------

/// Parse the superblock in `mnt.sb` and fill in the geometry. Returns false
/// when it is not an ext2 filesystem or uses features this code cannot read.
fn parseSuper(mnt: *Ext2Mount) bool {
    const sb: []const u8 = &mnt.sb;
    if (rd16(sb, 56) != SUPER_MAGIC) return false;
    const log_block: u32 = rd32(sb, 24);
    if (log_block > 2) return false;
    mnt.block_size = @as(u64, 1024) << @intCast(log_block);
    mnt.inodes_count = rd32(sb, 0);
    mnt.blocks_count = rd32(sb, 4);
    mnt.first_data_block = rd32(sb, 20);
    mnt.blocks_per_group = rd32(sb, 32);
    mnt.inodes_per_group = rd32(sb, 40);
    mnt.rev = rd32(sb, 76);
    if (mnt.blocks_per_group == 0 or mnt.inodes_per_group == 0) return false;
    if (mnt.rev >= 1) {
        mnt.first_ino = rd32(sb, 84);
        const isz: u16 = rd16(sb, 88);
        mnt.inode_size = if (isz == 0) DEFAULT_INODE_SIZE else isz;
        mnt.feature_incompat = rd32(sb, 96);
    }
    mnt.ngroups = (mnt.blocks_count - mnt.first_data_block + mnt.blocks_per_group - 1) / mnt.blocks_per_group;
    // Extents, 64-bit block numbers, meta_bg and the like change the layout.
    if ((mnt.feature_incompat & ~INCOMPAT_SUPP) != 0) return false;
    return true;
}

/// Whether the filesystem can be written: only features the allocator
/// keeps consistent, and no journal waiting for recovery.
pub fn writable(mnt: *const Ext2Mount) bool {
    if (mnt.rev == 0) return true;
    const ro: u32 = rd32(&mnt.sb, 100);
    return (ro & ~ROCOMPAT_SUPP) == 0 and (mnt.feature_incompat & EXT2F_INCOMPAT_RECOVER) == 0;
}

/// Prepare `mnt` for the in-memory, read-only filesystem `image`. Returns
/// false when `image` is not an ext2 filesystem.
pub fn mountInit(mnt: *Ext2Mount, image: []const u8) bool {
    mnt.* = .{};
    if (image.len < SUPER_OFFSET + SUPER_SIZE) return false;
    mnt.image = @constCast(image);
    @memcpy(&mnt.sb, image[SUPER_OFFSET .. SUPER_OFFSET + SUPER_SIZE]);
    mnt.readonly = true;
    return parseSuper(mnt);
}

/// Prepare `mnt` for the filesystem on `dp`. Returns false when it holds
/// no ext2 filesystem this code can read.
pub fn mountDisk(mnt: *Ext2Mount, dp: *geom_disk.Disk, readonly: bool) bool {
    mnt.* = .{};
    mnt.disk = dp;
    // The superblock is at byte 1024 whatever the block size: read it
    // through a 1 KiB view of the disk.
    const bp: *vfs_bio.Buf = vfs_bio.bread(dp, SUPER_OFFSET, SUPER_SIZE) orelse return false;
    @memcpy(&mnt.sb, bp.b_data[0..SUPER_SIZE]);
    vfs_bio.brelse(bp);
    // Drop that 1 KiB buffer: the filesystem reads the same bytes as part
    // of a whole block, and two buffers must not alias one sector.
    vfs_bio.binval(dp);
    if (!parseSuper(mnt)) return false;
    mnt.readonly = readonly or dp.d_readonly or !writable(mnt);
    return true;
}

/// Write the in-memory superblock back to its block.
pub fn writeSuper(mnt: *Ext2Mount) void {
    if (mnt.readonly or mnt.disk == null) return;
    const bno: u64 = SUPER_OFFSET / mnt.block_size;
    const off: u64 = SUPER_OFFSET % mnt.block_size;
    const b: Blk = bget(mnt, bno) orelse return;
    @memcpy(b.data[@intCast(off)..@intCast(off + SUPER_SIZE)], &mnt.sb);
    bdirty(b);
    mnt.sb_dirty = false;
}

/// Free block and inode counts, from the superblock.
pub fn freeBlocks(mnt: *const Ext2Mount) u64 {
    return rd32(&mnt.sb, 12);
}

pub fn freeInodes(mnt: *const Ext2Mount) u64 {
    return rd32(&mnt.sb, 16);
}

pub fn reservedBlocks(mnt: *const Ext2Mount) u64 {
    return rd32(&mnt.sb, 8);
}

pub fn superState(mnt: *const Ext2Mount) u16 {
    return rd16(&mnt.sb, 58);
}

pub fn setSuperState(mnt: *Ext2Mount, state: u16) void {
    wr16(&mnt.sb, 58, state);
    mnt.sb_dirty = true;
}

/// Note a mount in the superblock (mount count and time).
pub fn noteMount(mnt: *Ext2Mount, now: u32) void {
    wr16(&mnt.sb, 52, rd16(&mnt.sb, 52) +% 1);
    wr32(&mnt.sb, 44, now);
    wr32(&mnt.sb, 48, now);
    mnt.sb_dirty = true;
}

// -- group descriptors ------------------------------------------------------------

/// The block and offset of group `g`'s descriptor.
fn gdLocation(mnt: *const Ext2Mount, g: u64) struct { bno: u64, off: u64 } {
    const per_block: u64 = mnt.block_size / GD_SIZE;
    return .{ .bno = mnt.first_data_block + 1 + g / per_block, .off = (g % per_block) * GD_SIZE };
}

/// Read field `field` (a byte offset) of group `g`'s descriptor.
fn gdRead32(mnt: *Ext2Mount, g: u64, field: u64) u32 {
    const loc = gdLocation(mnt, g);
    const b: Blk = bget(mnt, loc.bno) orelse return 0;
    defer brelse(b);
    return rd32(b.data, loc.off + field);
}

/// Add `delta` to the 16-bit counter `field` of group `g`'s descriptor.
fn gdAdjust16(mnt: *Ext2Mount, g: u64, field: u64, delta: i32) void {
    const loc = gdLocation(mnt, g);
    const b: Blk = bget(mnt, loc.bno) orelse return;
    const v: i32 = @as(i32, rd16(b.data, loc.off + field)) + delta;
    wr16(b.data, loc.off + field, @intCast(@max(v, 0)));
    bdirty(b);
}

const GD_BLOCK_BITMAP: u64 = 0;
const GD_INODE_BITMAP: u64 = 4;
const GD_INODE_TABLE: u64 = 8;
const GD_FREE_BLOCKS: u64 = 12;
const GD_FREE_INODES: u64 = 14;
const GD_USED_DIRS: u64 = 16;

/// Add `delta` to a 32-bit superblock counter.
fn sbAdjust32(mnt: *Ext2Mount, off: u64, delta: i64) void {
    const v: i64 = @as(i64, rd32(&mnt.sb, off)) + delta;
    wr32(&mnt.sb, off, @intCast(@max(v, 0)));
    mnt.sb_dirty = true;
}

// -- inodes ------------------------------------------------------------------------

/// The block and offset of inode `ino`.
fn inodeLocation(mnt: *Ext2Mount, ino: u64) ?struct { bno: u64, off: u64 } {
    if (ino == 0 or ino > mnt.inodes_count) return null;
    const group: u64 = (ino - 1) / mnt.inodes_per_group;
    const index: u64 = (ino - 1) % mnt.inodes_per_group;
    const itable: u64 = gdRead32(mnt, group, GD_INODE_TABLE);
    if (itable == 0) return null;
    const byte: u64 = index * mnt.inode_size;
    return .{ .bno = itable + byte / mnt.block_size, .off = byte % mnt.block_size };
}

/// Read inode `ino`, or null when it does not exist.
pub fn readInode(mnt: *Ext2Mount, ino: u64) ?Inode {
    const loc = inodeLocation(mnt, ino) orelse return null;
    const b: Blk = bget(mnt, loc.bno) orelse return null;
    defer brelse(b);
    const d: []const u8 = b.data[@intCast(loc.off)..];
    var in: Inode = .{};
    in.mode = rd16(d, 0);
    in.uid = @as(u32, rd16(d, 2)) | (@as(u32, rd16(d, 120)) << 16);
    in.size = rd32(d, 4);
    in.atime = rd32(d, 8);
    in.ctime = rd32(d, 12);
    in.mtime = rd32(d, 16);
    in.dtime = rd32(d, 20);
    in.gid = @as(u32, rd16(d, 24)) | (@as(u32, rd16(d, 122)) << 16);
    in.nlink = rd16(d, 26);
    in.blocks = rd32(d, 28);
    in.flags = rd32(d, 32);
    for (&in.block, 0..) |*p, i| p.* = rd32(d, 40 + @as(u64, i) * 4);
    // Regular files keep the high half of a large size in i_size_high.
    if ((in.mode & S_IFMT) == S_IFREG and mnt.rev >= 1) {
        in.size |= @as(u64, rd32(d, 108)) << 32;
    }
    return in;
}

/// Write `in` back as inode `ino`, keeping the fields this code does not
/// manage (extended attributes, extra fields).
pub fn writeInode(mnt: *Ext2Mount, ino: u64, in: *const Inode) Error!void {
    if (mnt.readonly) return error.ReadOnly;
    const loc = inodeLocation(mnt, ino) orelse return error.Io;
    const b: Blk = bget(mnt, loc.bno) orelse return error.Io;
    const d: []u8 = b.data[@intCast(loc.off)..];
    wr16(d, 0, in.mode);
    wr16(d, 2, @truncate(in.uid));
    wr16(d, 120, @truncate(in.uid >> 16));
    wr32(d, 4, @truncate(in.size));
    wr32(d, 8, @intCast(in.atime & 0xffff_ffff));
    wr32(d, 12, @intCast(in.ctime & 0xffff_ffff));
    wr32(d, 16, @intCast(in.mtime & 0xffff_ffff));
    wr32(d, 20, @intCast(in.dtime & 0xffff_ffff));
    wr16(d, 24, @truncate(in.gid));
    wr16(d, 122, @truncate(in.gid >> 16));
    wr16(d, 26, @intCast(@min(in.nlink, 0xffff)));
    wr32(d, 28, @truncate(in.blocks));
    wr32(d, 32, in.flags);
    for (in.block, 0..) |p, i| wr32(d, 40 + @as(u64, i) * 4, p);
    if ((in.mode & S_IFMT) == S_IFREG and mnt.rev >= 1) {
        wr32(d, 108, @truncate(in.size >> 32));
        if (in.size > 0x7fff_ffff and (rd32(&mnt.sb, 100) & EXT2F_ROCOMPAT_LARGEFILE) == 0) {
            sbAdjust32(mnt, 100, EXT2F_ROCOMPAT_LARGEFILE);
        }
    }
    bdirty(b);
}

/// Clear inode `ino` on disk (all bytes), before it is first used.
fn clearInode(mnt: *Ext2Mount, ino: u64) Error!void {
    const loc = inodeLocation(mnt, ino) orelse return error.Io;
    const b: Blk = bget(mnt, loc.bno) orelse return error.Io;
    @memset(b.data[@intCast(loc.off)..@intCast(loc.off + mnt.inode_size)], 0);
    bdirty(b);
}

/// The vnode type matching an on-disk mode.
pub fn vtypeOf(mode: u16) vnode.Vtype {
    return switch (mode & S_IFMT) {
        S_IFREG => .vreg,
        S_IFDIR => .vdir,
        S_IFCHR => .vchr,
        S_IFBLK => .vblk,
        S_IFLNK => .vlnk,
        S_IFIFO => .vfifo,
        S_IFSOCK => .vsock,
        else => .vnone,
    };
}

/// The S_IFMT bits for a vnode type.
pub fn modeOf(t: vnode.Vtype) u16 {
    return switch (t) {
        .vreg => S_IFREG,
        .vdir => S_IFDIR,
        .vchr => S_IFCHR,
        .vblk => S_IFBLK,
        .vlnk => S_IFLNK,
        .vfifo => S_IFIFO,
        .vsock => S_IFSOCK,
        else => 0,
    };
}

/// The directory entry file type for a mode.
fn ftypeOf(mode: u16) u8 {
    return switch (mode & S_IFMT) {
        S_IFREG => FT_REG,
        S_IFDIR => FT_DIR,
        S_IFCHR => FT_CHR,
        S_IFBLK => FT_BLK,
        S_IFLNK => FT_LNK,
        S_IFIFO => FT_FIFO,
        S_IFSOCK => FT_SOCK,
        else => FT_UNKNOWN,
    };
}

// -- allocation (ext2_alloc.c) ----------------------------------------------------

/// Find and set a clear bit among the first `nbits` of bitmap block `bno`.
fn bitmapTake(mnt: *Ext2Mount, bno: u64, nbits: u64, first: u64) ?u64 {
    const b: Blk = bget(mnt, bno) orelse return null;
    var i: u64 = first;
    while (i < nbits) : (i += 1) {
        const byte: usize = @intCast(i / 8);
        const bit: u3 = @intCast(i % 8);
        if (b.data[byte] == 0xff) {
            i += 7 - @as(u64, bit);
            continue;
        }
        if ((b.data[byte] & (@as(u8, 1) << bit)) == 0) {
            b.data[byte] |= @as(u8, 1) << bit;
            bdirty(b);
            return i;
        }
    }
    brelse(b);
    return null;
}

/// Clear bit `i` of bitmap block `bno`.
fn bitmapRelease(mnt: *Ext2Mount, bno: u64, i: u64) void {
    const b: Blk = bget(mnt, bno) orelse return;
    b.data[@intCast(i / 8)] &= ~(@as(u8, 1) << @intCast(i % 8));
    bdirty(b);
}

/// Blocks in group `g` (the last group may be short).
fn groupBlocks(mnt: *const Ext2Mount, g: u64) u64 {
    const start: u64 = mnt.first_data_block + g * mnt.blocks_per_group;
    return @min(mnt.blocks_per_group, mnt.blocks_count - start);
}

/// Allocate a block, preferring group `goal`. The block is not cleared.
fn allocBlock(mnt: *Ext2Mount, goal: u64) Error!u64 {
    if (mnt.readonly) return error.ReadOnly;
    if (freeBlocks(mnt) == 0) return error.NoSpace;
    var n: u64 = 0;
    while (n < mnt.ngroups) : (n += 1) {
        const g: u64 = (goal + n) % mnt.ngroups;
        const loc = gdLocation(mnt, g);
        const b: Blk = bget(mnt, loc.bno) orelse return error.Io;
        const nfree: u16 = rd16(b.data, loc.off + GD_FREE_BLOCKS);
        const bitmap: u32 = rd32(b.data, loc.off + GD_BLOCK_BITMAP);
        brelse(b);
        if (nfree == 0) continue;
        const bit: u64 = bitmapTake(mnt, bitmap, groupBlocks(mnt, g), 0) orelse continue;
        gdAdjust16(mnt, g, GD_FREE_BLOCKS, -1);
        sbAdjust32(mnt, 12, -1);
        return mnt.first_data_block + g * mnt.blocks_per_group + bit;
    }
    return error.NoSpace;
}

/// Free block `bno`.
fn freeBlock(mnt: *Ext2Mount, bno: u64) void {
    if (bno < mnt.first_data_block or bno >= mnt.blocks_count) return;
    const rel: u64 = bno - mnt.first_data_block;
    const g: u64 = rel / mnt.blocks_per_group;
    bitmapRelease(mnt, gdRead32(mnt, g, GD_BLOCK_BITMAP), rel % mnt.blocks_per_group);
    gdAdjust16(mnt, g, GD_FREE_BLOCKS, 1);
    sbAdjust32(mnt, 12, 1);
}

/// Allocate an inode near `parent` (directories go to the group with the
/// most free inodes, as Orlov-less ext2 did). The inode is cleared.
pub fn allocInode(mnt: *Ext2Mount, parent: u64, dir: bool) Error!u64 {
    if (mnt.readonly) return error.ReadOnly;
    if (freeInodes(mnt) == 0) return error.NoSpace;
    var goal: u64 = if (parent > 0) (parent - 1) / mnt.inodes_per_group else 0;
    if (dir) {
        var best: u64 = 0;
        var g: u64 = 0;
        while (g < mnt.ngroups) : (g += 1) {
            const loc = gdLocation(mnt, g);
            const b: Blk = bget(mnt, loc.bno) orelse return error.Io;
            const nfree: u64 = rd16(b.data, loc.off + GD_FREE_INODES);
            brelse(b);
            if (nfree > best) {
                best = nfree;
                goal = g;
            }
        }
    }
    var n: u64 = 0;
    while (n < mnt.ngroups) : (n += 1) {
        const g: u64 = (goal + n) % mnt.ngroups;
        const loc = gdLocation(mnt, g);
        const b: Blk = bget(mnt, loc.bno) orelse return error.Io;
        const nfree: u16 = rd16(b.data, loc.off + GD_FREE_INODES);
        const bitmap: u32 = rd32(b.data, loc.off + GD_INODE_BITMAP);
        brelse(b);
        if (nfree == 0) continue;
        // Inodes below first_ino are reserved (root, journal, ...).
        const first: u64 = if (g == 0) mnt.first_ino - 1 else 0;
        const bit: u64 = bitmapTake(mnt, bitmap, mnt.inodes_per_group, first) orelse continue;
        gdAdjust16(mnt, g, GD_FREE_INODES, -1);
        if (dir) gdAdjust16(mnt, g, GD_USED_DIRS, 1);
        sbAdjust32(mnt, 16, -1);
        const ino: u64 = g * mnt.inodes_per_group + bit + 1;
        try clearInode(mnt, ino);
        return ino;
    }
    return error.NoSpace;
}

/// Free inode `ino`.
fn freeInode(mnt: *Ext2Mount, ino: u64, dir: bool) void {
    const g: u64 = (ino - 1) / mnt.inodes_per_group;
    bitmapRelease(mnt, gdRead32(mnt, g, GD_INODE_BITMAP), (ino - 1) % mnt.inodes_per_group);
    gdAdjust16(mnt, g, GD_FREE_INODES, 1);
    if (dir) gdAdjust16(mnt, g, GD_USED_DIRS, -1);
    sbAdjust32(mnt, 16, 1);
}

/// Allocate a zero-filled block for inode `ino` and count it in `in`.
fn allocZeroed(mnt: *Ext2Mount, ino: u64, in: *Inode) Error!u32 {
    const bno: u64 = try allocBlock(mnt, (ino - 1) / mnt.inodes_per_group);
    const b: Blk = bnew(mnt, bno) orelse return error.Io;
    bdirty(b);
    in.blocks += mnt.block_size / 512;
    return @intCast(bno);
}

// -- block mapping (ext2_bmap.c, ext2_balloc.c) -----------------------------------

/// Where logical block `lbn` hangs: the level of indirection (0 direct) and
/// the index below the root pointer.
fn mapPath(mnt: *const Ext2Mount, lbn: u64) ?struct { level: u32, idx: u64, span: u64 } {
    if (lbn < 12) return .{ .level = 0, .idx = lbn, .span = 1 };
    const per: u64 = mnt.block_size / 4;
    var idx: u64 = lbn - 12;
    var level: u32 = 1;
    var span: u64 = per;
    while (idx >= span) {
        idx -= span;
        level += 1;
        if (level > 3) return null;
        span *= per;
    }
    return .{ .level = level, .idx = idx, .span = span };
}

/// Map logical file block `lbn` to a filesystem block, or null for a hole.
pub fn bmap(mnt: *Ext2Mount, in: *const Inode, lbn: u64) ?u64 {
    const path = mapPath(mnt, lbn) orelse return null;
    if (path.level == 0) {
        const b: u32 = in.block[@intCast(lbn)];
        return if (b == 0) null else b;
    }
    const per: u64 = mnt.block_size / 4;
    var blk: u64 = in.block[11 + path.level];
    var span: u64 = path.span;
    var idx: u64 = path.idx;
    var l: u32 = path.level;
    while (l > 0) : (l -= 1) {
        if (blk == 0) return null;
        span /= per;
        const b: Blk = bget(mnt, blk) orelse return null;
        blk = rd32(b.data, (idx / span) * 4);
        brelse(b);
        idx %= span;
    }
    return if (blk == 0) null else blk;
}

/// Map logical block `lbn` of inode `ino`, allocating it (and any missing
/// indirect blocks, zero-filled) when it is a hole. `fresh` is set when the
/// data block was just allocated.
fn bmapAlloc(mnt: *Ext2Mount, ino: u64, in: *Inode, lbn: u64, fresh: *bool) Error!u64 {
    fresh.* = false;
    const path = mapPath(mnt, lbn) orelse return error.TooBig;
    if (path.level == 0) {
        const i: usize = @intCast(lbn);
        if (in.block[i] == 0) {
            in.block[i] = try allocZeroed(mnt, ino, in);
            fresh.* = true;
        }
        return in.block[i];
    }
    const per: u64 = mnt.block_size / 4;
    const root: usize = 11 + path.level;
    if (in.block[root] == 0) in.block[root] = try allocZeroed(mnt, ino, in);
    var blk: u64 = in.block[root];
    var span: u64 = path.span;
    var idx: u64 = path.idx;
    var l: u32 = path.level;
    while (l > 0) : (l -= 1) {
        span /= per;
        const slot: u64 = (idx / span) * 4;
        idx %= span;
        const b: Blk = bget(mnt, blk) orelse return error.Io;
        var e: u32 = rd32(b.data, slot);
        if (e == 0) {
            e = allocZeroed(mnt, ino, in) catch |err| {
                brelse(b);
                return err;
            };
            wr32(b.data, slot, e);
            bdirty(b);
            if (l == 1) fresh.* = true;
        } else {
            brelse(b);
        }
        blk = e;
    }
    return blk;
}

/// Free the subtree under indirect block `ptr` (at `level`, covering file
/// blocks from `base`) that lies at or past file block `keep`. Clears `ptr`
/// when the whole subtree goes.
fn freeTree(mnt: *Ext2Mount, in: *Inode, ptr: *u32, level: u32, base: u64, keep: u64) void {
    if (ptr.* == 0) return;
    const per: u64 = mnt.block_size / 4;
    var span: u64 = 1;
    var k: u32 = 0;
    while (k < level) : (k += 1) span *= per;
    if (base + span <= keep) return; // entirely kept
    const child_span: u64 = span / per;
    if (bget(mnt, ptr.*)) |b| {
        var changed: bool = false;
        var i: u64 = 0;
        while (i < per) : (i += 1) {
            var e: u32 = rd32(b.data, i * 4);
            if (e == 0) continue;
            const cbase: u64 = base + i * child_span;
            if (level == 1) {
                if (cbase >= keep) {
                    freeBlock(mnt, e);
                    in.blocks -|= mnt.block_size / 512;
                    e = 0;
                }
            } else {
                freeTree(mnt, in, &e, level - 1, cbase, keep);
            }
            if (e != rd32(b.data, i * 4)) {
                wr32(b.data, i * 4, e);
                changed = true;
            }
        }
        if (changed) bdirty(b) else brelse(b);
    }
    if (base >= keep) {
        freeBlock(mnt, ptr.*);
        in.blocks -|= mnt.block_size / 512;
        ptr.* = 0;
    }
}

/// Free every block of `in` from file block `keep` on.
fn truncateBlocks(mnt: *Ext2Mount, in: *Inode, keep: u64) void {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        if (i >= keep and in.block[i] != 0) {
            freeBlock(mnt, in.block[i]);
            in.blocks -|= mnt.block_size / 512;
            in.block[i] = 0;
        }
    }
    const per: u64 = mnt.block_size / 4;
    var base: u64 = 12;
    var span: u64 = per;
    var level: u32 = 1;
    while (level <= 3) : (level += 1) {
        freeTree(mnt, in, &in.block[11 + level], level, base, keep);
        base += span;
        span *= per;
    }
}

/// Whether `in` keeps its data in blocks (not an inline symbolic link or a
/// device node, whose block array holds other things).
fn hasBlocks(in: *const Inode) bool {
    return switch (in.mode & S_IFMT) {
        S_IFREG, S_IFDIR => true,
        S_IFLNK => in.size >= MAXSYMLINKLEN or in.blocks != 0,
        else => false,
    };
}

/// Change the size of `in` (inode `ino`) to `length`, freeing the blocks
/// past it and zeroing the rest of the last kept block.
pub fn truncate(mnt: *Ext2Mount, ino: u64, in: *Inode, length: u64, now: i64) Error!void {
    if (mnt.readonly) return error.ReadOnly;
    if (hasBlocks(in) and length < in.size) {
        const bs: u64 = mnt.block_size;
        const keep: u64 = (length + bs - 1) / bs;
        truncateBlocks(mnt, in, keep);
        if (length % bs != 0) {
            if (bmap(mnt, in, length / bs)) |bno| {
                if (bget(mnt, bno)) |b| {
                    @memset(b.data[@intCast(length % bs)..], 0);
                    bdirty(b);
                }
            }
        }
    } else if ((in.mode & S_IFMT) == S_IFLNK and length == 0) {
        in.block = @splat(0);
    }
    in.size = length;
    in.mtime = now;
    in.ctime = now;
    try writeInode(mnt, ino, in);
}

// -- file data ---------------------------------------------------------------------

/// Copy up to `buf.len` bytes of a file at `offset`; returns the count.
/// A hole (a zero block pointer) reads as zeroes.
pub fn readData(mnt: *Ext2Mount, in: *const Inode, offset: u64, buf: []u8) usize {
    if (offset >= in.size) return 0;
    const want: usize = @intCast(@min(@as(u64, buf.len), in.size - offset));
    const bs: u64 = mnt.block_size;
    var done: usize = 0;
    while (done < want) {
        const pos: u64 = offset + done;
        const boff: usize = @intCast(pos % bs);
        const n: usize = @min(@as(usize, @intCast(bs)) - boff, want - done);
        if (bmap(mnt, in, pos / bs)) |bno| {
            const b: Blk = bget(mnt, bno) orelse break;
            @memcpy(buf[done .. done + n], b.data[boff .. boff + n]);
            brelse(b);
        } else {
            @memset(buf[done .. done + n], 0);
        }
        done += n;
    }
    return done;
}

/// Write `buf` at `offset` into inode `ino`, growing it as needed. Returns
/// the bytes written (fewer when the disk fills up after some progress).
pub fn writeData(mnt: *Ext2Mount, ino: u64, in: *Inode, offset: u64, buf: []const u8, now: i64) Error!usize {
    if (mnt.readonly) return error.ReadOnly;
    const bs: u64 = mnt.block_size;
    var done: usize = 0;
    var failure: ?Error = null;
    while (done < buf.len) {
        const pos: u64 = offset + done;
        const boff: usize = @intCast(pos % bs);
        const n: usize = @min(@as(usize, @intCast(bs)) - boff, buf.len - done);
        var fresh: bool = false;
        const bno: u64 = bmapAlloc(mnt, ino, in, pos / bs, &fresh) catch |err| {
            failure = err;
            break;
        };
        // A block overwritten whole need not be read first (a freshly
        // allocated one is already zeroed in the cache).
        const b: Blk = (if (!fresh and boff == 0 and n == bs) bnew(mnt, bno) else bget(mnt, bno)) orelse {
            failure = error.Io;
            break;
        };
        @memcpy(b.data[boff .. boff + n], buf[done .. done + n]);
        bdirty(b);
        done += n;
    }
    if (offset + done > in.size) in.size = offset + done;
    if (done > 0) {
        in.mtime = now;
        in.ctime = now;
    }
    try writeInode(mnt, ino, in);
    if (done == 0) {
        if (failure) |e| return e;
    }
    return done;
}

/// Read a symbolic link's target into `buf`; returns its length, or -1 when
/// there is no room.
pub fn readLink(mnt: *Ext2Mount, in: *const Inode, buf: []u8) isize {
    if (in.size == 0 or in.size > buf.len) return -1;
    if (in.size < MAXSYMLINKLEN and in.blocks == 0) {
        // The target is stored inline in the block pointer array.
        const src: []const u8 = @as([*]const u8, @ptrCast(&in.block))[0..@intCast(in.size)];
        @memcpy(buf[0..src.len], src);
        return @intCast(in.size);
    }
    return @intCast(readData(mnt, in, 0, buf[0..@intCast(in.size)]));
}

/// Store `target` as the contents of the symbolic link `ino`: inline when
/// short (a "fast" link), else in a data block.
pub fn writeLink(mnt: *Ext2Mount, ino: u64, in: *Inode, target: []const u8, now: i64) Error!void {
    if (target.len < MAXSYMLINKLEN) {
        in.block = @splat(0);
        @memcpy(@as([*]u8, @ptrCast(&in.block))[0..target.len], target);
        in.size = target.len;
        in.mtime = now;
        in.ctime = now;
        return writeInode(mnt, ino, in);
    }
    _ = try writeData(mnt, ino, in, 0, target, now);
}

// -- directories (ext2_lookup.c) ---------------------------------------------------

/// One directory entry returned by `dirNext`.
pub const DirEntry = struct {
    ino: u64,
    ftype: u8,
    name: [256]u8,
    name_len: usize,
};

/// Length of a directory entry holding a name of `len` bytes.
fn direntSize(len: usize) u64 {
    return (8 + @as(u64, len) + 3) & ~@as(u64, 3);
}

/// Whether the filesystem records file types in directory entries.
fn hasFtype(mnt: *const Ext2Mount) bool {
    return (mnt.feature_incompat & EXT2F_INCOMPAT_FTYPE) != 0;
}

/// The name length stored in entry `e` (a 16-bit field without file types).
fn entNameLen(mnt: *const Ext2Mount, d: []const u8, e: u64) usize {
    return if (hasFtype(mnt)) d[@intCast(e + 6)] else rd16(d, e + 6);
}

/// Return the next live entry of directory `dir` at or after `pos.*`,
/// advancing `pos.*` past it. Returns false at the end of the directory.
pub fn dirNext(mnt: *Ext2Mount, dir: *const Inode, pos: *u64, out: *DirEntry) bool {
    const bs: u64 = mnt.block_size;
    while (pos.* < dir.size) {
        const bno: u64 = bmap(mnt, dir, pos.* / bs) orelse return false;
        const b: Blk = bget(mnt, bno) orelse return false;
        defer brelse(b);
        const e: u64 = pos.* % bs;
        const ino: u32 = rd32(b.data, e);
        const rec_len: u16 = rd16(b.data, e + 4);
        if (rec_len < 8 or e + rec_len > bs) return false;
        const nl: usize = entNameLen(mnt, b.data, e);
        pos.* += rec_len;
        if (ino != 0 and nl > 0 and nl <= out.name.len and e + 8 + nl <= bs) {
            @memcpy(out.name[0..nl], b.data[@intCast(e + 8)..@intCast(e + 8 + nl)]);
            out.ino = ino;
            out.ftype = if (hasFtype(mnt)) b.data[@intCast(e + 7)] else FT_UNKNOWN;
            out.name_len = nl;
            return true;
        }
    }
    return false;
}

/// Find `name` in directory `dir`; returns its inode number, or null.
pub fn dirLookup(mnt: *Ext2Mount, dir: *const Inode, name: []const u8) ?u64 {
    if ((dir.mode & S_IFMT) != S_IFDIR) return null;
    var pos: u64 = 0;
    var ent: DirEntry = undefined;
    while (dirNext(mnt, dir, &pos, &ent)) {
        if (ent.name_len == name.len and std_eql(ent.name[0..ent.name_len], name)) return ent.ino;
    }
    return null;
}

fn std_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Write an entry for `name` -> `ino` at offset `e` of block data `d`,
/// spanning `rec_len` bytes.
fn putEntry(mnt: *const Ext2Mount, d: []u8, e: u64, ino: u64, rec_len: u64, name: []const u8, ftype: u8) void {
    wr32(d, e, @intCast(ino));
    wr16(d, e + 4, @intCast(rec_len));
    if (hasFtype(mnt)) {
        d[@intCast(e + 6)] = @intCast(name.len);
        d[@intCast(e + 7)] = ftype;
    } else {
        wr16(d, e + 6, @intCast(name.len));
    }
    @memcpy(d[@intCast(e + 8)..@intCast(e + 8 + name.len)], name);
}

/// Add the entry `name` -> `ino` to directory `dino`, reusing free space in
/// an existing block or appending a block (ext2_direnter).
pub fn dirEnter(mnt: *Ext2Mount, dino: u64, dir: *Inode, name: []const u8, ino: u64, mode: u16, now: i64) Error!void {
    if (mnt.readonly) return error.ReadOnly;
    const bs: u64 = mnt.block_size;
    const need: u64 = direntSize(name.len);
    const ftype: u8 = ftypeOf(mode);
    // The hashed index would go stale: fall back to a linear directory, as
    // a kernel without dir_index support does.
    dir.flags &= ~EXT2_INDEX_FL;

    var lbn: u64 = 0;
    const nblocks: u64 = (dir.size + bs - 1) / bs;
    while (lbn < nblocks) : (lbn += 1) {
        const bno: u64 = bmap(mnt, dir, lbn) orelse continue;
        const b: Blk = bget(mnt, bno) orelse return error.Io;
        var e: u64 = 0;
        while (e < bs) {
            const eino: u32 = rd32(b.data, e);
            const rec_len: u64 = rd16(b.data, e + 4);
            if (rec_len < 8 or e + rec_len > bs) break;
            const used: u64 = if (eino == 0) 0 else direntSize(entNameLen(mnt, b.data, e));
            if (rec_len - used >= need) {
                if (eino == 0) {
                    putEntry(mnt, b.data, e, ino, rec_len, name, ftype);
                } else {
                    wr16(b.data, e + 4, @intCast(used));
                    putEntry(mnt, b.data, e + used, ino, rec_len - used, name, ftype);
                }
                bdirty(b);
                dir.mtime = now;
                dir.ctime = now;
                return writeInode(mnt, dino, dir);
            }
            e += rec_len;
        }
        brelse(b);
    }

    // No room: a new block holding just this entry.
    var fresh: bool = false;
    const bno: u64 = try bmapAlloc(mnt, dino, dir, nblocks, &fresh);
    const b: Blk = bget(mnt, bno) orelse return error.Io;
    @memset(b.data, 0);
    putEntry(mnt, b.data, 0, ino, bs, name, ftype);
    bdirty(b);
    dir.size = (nblocks + 1) * bs;
    dir.mtime = now;
    dir.ctime = now;
    return writeInode(mnt, dino, dir);
}

/// Remove the entry `name` from directory `dino`; returns the inode it
/// named, or null when there is none (ext2_dirremove).
pub fn dirRemove(mnt: *Ext2Mount, dino: u64, dir: *Inode, name: []const u8, now: i64) Error!?u64 {
    if (mnt.readonly) return error.ReadOnly;
    const bs: u64 = mnt.block_size;
    const nblocks: u64 = (dir.size + bs - 1) / bs;
    var lbn: u64 = 0;
    while (lbn < nblocks) : (lbn += 1) {
        const bno: u64 = bmap(mnt, dir, lbn) orelse continue;
        const b: Blk = bget(mnt, bno) orelse return error.Io;
        var e: u64 = 0;
        var prev: ?u64 = null;
        while (e < bs) {
            const eino: u32 = rd32(b.data, e);
            const rec_len: u64 = rd16(b.data, e + 4);
            if (rec_len < 8 or e + rec_len > bs) break;
            const nl: usize = entNameLen(mnt, b.data, e);
            if (eino != 0 and nl == name.len and std_eql(b.data[@intCast(e + 8)..@intCast(e + 8 + nl)], name)) {
                if (prev) |p| {
                    // Fold the entry into the one before it.
                    wr16(b.data, p + 4, @intCast(rd16(b.data, p + 4) + rec_len));
                } else {
                    wr32(b.data, e, 0);
                }
                bdirty(b);
                dir.flags &= ~EXT2_INDEX_FL;
                dir.mtime = now;
                dir.ctime = now;
                try writeInode(mnt, dino, dir);
                return eino;
            }
            prev = e;
            e += rec_len;
        }
        brelse(b);
    }
    return null;
}

/// Point the entry `name` of directory `dino` at `ino` (".." after a
/// directory moves).
pub fn dirRewrite(mnt: *Ext2Mount, dir: *const Inode, name: []const u8, ino: u64, mode: u16) Error!void {
    const bs: u64 = mnt.block_size;
    const nblocks: u64 = (dir.size + bs - 1) / bs;
    var lbn: u64 = 0;
    while (lbn < nblocks) : (lbn += 1) {
        const bno: u64 = bmap(mnt, dir, lbn) orelse continue;
        const b: Blk = bget(mnt, bno) orelse return error.Io;
        var e: u64 = 0;
        while (e < bs) {
            const rec_len: u64 = rd16(b.data, e + 4);
            if (rec_len < 8 or e + rec_len > bs) break;
            const nl: usize = entNameLen(mnt, b.data, e);
            if (rd32(b.data, e) != 0 and nl == name.len and std_eql(b.data[@intCast(e + 8)..@intCast(e + 8 + nl)], name)) {
                wr32(b.data, e, @intCast(ino));
                if (hasFtype(mnt)) b.data[@intCast(e + 7)] = ftypeOf(mode);
                bdirty(b);
                return;
            }
            e += rec_len;
        }
        brelse(b);
    }
}

/// Whether directory `dir` holds nothing but "." and "..".
pub fn dirEmpty(mnt: *Ext2Mount, dir: *const Inode) bool {
    var pos: u64 = 0;
    var ent: DirEntry = undefined;
    while (dirNext(mnt, dir, &pos, &ent)) {
        const n: []const u8 = ent.name[0..ent.name_len];
        if (std_eql(n, ".") or std_eql(n, "..")) continue;
        return false;
    }
    return true;
}

/// Fill a new directory's first block with "." and "..".
pub fn dirInit(mnt: *Ext2Mount, ino: u64, in: *Inode, parent: u64, now: i64) Error!void {
    const bs: u64 = mnt.block_size;
    var fresh: bool = false;
    const bno: u64 = try bmapAlloc(mnt, ino, in, 0, &fresh);
    const b: Blk = bget(mnt, bno) orelse return error.Io;
    @memset(b.data, 0);
    putEntry(mnt, b.data, 0, ino, 12, ".", FT_DIR);
    putEntry(mnt, b.data, 12, parent, bs - 12, "..", FT_DIR);
    bdirty(b);
    in.size = bs;
    in.mtime = now;
    in.ctime = now;
}

/// Release inode `ino` and all its blocks (its last link is gone and no
/// file has it open).
pub fn release(mnt: *Ext2Mount, ino: u64, in: *Inode, now: i64) void {
    if (mnt.readonly) return;
    const dir: bool = (in.mode & S_IFMT) == S_IFDIR;
    if (hasBlocks(in)) truncateBlocks(mnt, in, 0);
    in.size = 0;
    in.nlink = 0;
    in.dtime = now;
    in.block = @splat(0);
    writeInode(mnt, ino, in) catch {};
    freeInode(mnt, ino, dir);
}
