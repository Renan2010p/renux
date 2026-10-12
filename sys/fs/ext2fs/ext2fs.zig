// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ext2fs filesystem: on-disk format.
//
// This is the Zig counterpart of NetBSD's sys/ufs/ext2fs (ext2fs.h together
// with the read side of ext2fs_bmap.c, ext2fs_lookup.c and ext2fs_vnops.c),
// reduced to the read-only path: parse the superblock, walk the group
// descriptors and inode table, map a file block through the direct and
// indirect block pointers, iterate a directory, and read file data. The image
// lives in memory -- it is loaded as a single boot module -- so there is no
// buffer cache or disk driver yet.

const vnode: type = @import("../../sys/vnode.zig");

/// Superblock magic (EXT2_SUPER_MAGIC).
pub const SUPER_MAGIC: u16 = 0xEF53;

/// Byte offset of the superblock within the filesystem.
const SUPER_OFFSET: u64 = 1024;

/// The root directory's inode number (EXT2_ROOT_INO).
pub const ROOT_INO: u64 = 2;

/// Size of an inode on disk when the superblock does not give one (ext2fs rev 0).
const DEFAULT_INODE_SIZE: u64 = 128;

/// Number of vnodes cached, keyed by inode number. ext2fs vnodes are never
/// reclaimed, so the cache just avoids handing out a fresh vnode for an inode
/// that already has one. It lives in .bss (a single ext2fs mount exists at a
/// time) so the mount record stays small enough for the kmem allocator.
pub const CACHE_N: usize = 2048;

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
pub const FT_REG: u8 = 1;
pub const FT_DIR: u8 = 2;
pub const FT_CHR: u8 = 3;
pub const FT_BLK: u8 = 4;
pub const FT_FIFO: u8 = 5;
pub const FT_SOCK: u8 = 6;
pub const FT_LNK: u8 = 7;

/// Arguments handed to the mount routine.
pub const Args = struct {
    image: []const u8,
};

/// A cached vnode, keyed by inode number.
pub const CacheEntry = struct {
    ino: u64,
    vp: *vnode.Vnode,
};

/// Per-mount state.
pub const Ext2Mount = struct {
    /// The whole filesystem image, in memory.
    image: []const u8,
    /// Block size in bytes (1024, 2048 or 4096).
    block_size: u64,
    /// Inodes per block group.
    inodes_per_group: u64,
    /// Inode size in bytes (128 or 256).
    inode_size: u64,
    /// First data block (1 for 1024-byte blocks, else 0).
    first_data_block: u64,
};

/// A parsed inode, the fields the read path needs.
pub const Inode = struct {
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64,
    nlink: u32,
    atime: i64,
    mtime: i64,
    ctime: i64,
    /// The fifteen block pointers (twelve direct, then single, double and
    /// triple indirect). For a short symbolic link the target lives here.
    block: [15]u32,
};

// -- little-endian readers, all bounds-checked --------------------------------

/// Little-endian readers, all bounds-checked.
pub fn rd16(img: []const u8, off: u64) u16 {
    if (off + 2 > img.len) {
        return 0;
    }
    return @as(u16, img[off]) | (@as(u16, img[off + 1]) << 8);
}

pub fn rd32(img: []const u8, off: u64) u32 {
    if (off + 4 > img.len) {
        return 0;
    }
    return @as(u32, img[off]) | (@as(u32, img[off + 1]) << 8) |
        (@as(u32, img[off + 2]) << 16) | (@as(u32, img[off + 3]) << 24);
}

// -- mount --------------------------------------------------------------------

/// Read the superblock and prepare `mnt`. Returns false when `image` is not an
/// ext2fs filesystem.
pub fn mountInit(mnt: *Ext2Mount, image: []const u8) bool {
    if (rd16(image, SUPER_OFFSET + 56) != SUPER_MAGIC) {
        return false;
    }
    const log_block: u32 = rd32(image, SUPER_OFFSET + 24);
    mnt.image = image;
    mnt.block_size = @as(u64, 1024) << @intCast(log_block & 0x7);
    mnt.first_data_block = rd32(image, SUPER_OFFSET + 20);
    mnt.inodes_per_group = rd32(image, SUPER_OFFSET + 40);
    const isz: u16 = rd16(image, SUPER_OFFSET + 88);
    mnt.inode_size = if (isz == 0) DEFAULT_INODE_SIZE else isz;
    return true;
}

/// Byte offset of the inode `ino` within the image, or null when it lies past
/// the end of the image.
fn inodeOffset(mnt: *const Ext2Mount, ino: u64) ?u64 {
    if (ino == 0 or mnt.inodes_per_group == 0) {
        return null;
    }
    const group: u64 = (ino - 1) / mnt.inodes_per_group;
    const index: u64 = (ino - 1) % mnt.inodes_per_group;

    // Group descriptor table starts in the block after the superblock.
    const gd: u64 = (mnt.first_data_block + 1) * mnt.block_size + group * 32;
    const itable: u64 = rd32(mnt.image, gd + 8);
    if (itable == 0) {
        return null;
    }
    const off: u64 = itable * mnt.block_size + index * mnt.inode_size;
    if (off + mnt.inode_size > mnt.image.len) {
        return null;
    }
    return off;
}

/// Read inode `ino`, or null when it does not exist.
pub fn readInode(mnt: *const Ext2Mount, ino: u64) ?Inode {
    const off: u64 = inodeOffset(mnt, ino) orelse return null;
    var in: Inode = undefined;
    in.mode = rd16(mnt.image, off + 0);
    in.uid = rd16(mnt.image, off + 2);
    in.size = rd32(mnt.image, off + 4);
    in.atime = rd32(mnt.image, off + 8);
    in.ctime = rd32(mnt.image, off + 12);
    in.mtime = rd32(mnt.image, off + 16);
    in.gid = rd16(mnt.image, off + 24);
    in.nlink = rd16(mnt.image, off + 26);
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        in.block[i] = rd32(mnt.image, off + 40 + @as(u64, i) * 4);
    }
    // Regular files use a 64-bit size once the revision is at least 1.
    if ((in.mode & S_IFMT) == S_IFREG and mnt.inode_size > 128) {
        const hi: u32 = rd32(mnt.image, off + 108);
        in.size = (@as(u64, hi) << 32) | in.size;
    }
    return in;
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

// -- block mapping ------------------------------------------------------------

/// The `index`-th block pointer stored in pointer block `pblock`.
fn entry(mnt: *const Ext2Mount, pblock: u32, index: u64) u32 {
    return rd32(mnt.image, @as(u64, pblock) * mnt.block_size + index * 4);
}

/// Map logical file block `lbn` to a filesystem block number, or null for a
/// hole. Direct, single- and double-indirect pointers are supported; a triple
/// indirect pointer (files larger than about 64 MiB with 1 KiB blocks) is not.
pub fn bmap(mnt: *const Ext2Mount, in: *const Inode, lbn: u64) ?u64 {
    const per: u64 = mnt.block_size / 4;

    if (lbn < 12) {
        const b: u32 = in.block[@intCast(lbn)];
        return if (b == 0) null else b;
    }

    var idx: u64 = lbn - 12;
    if (idx < per) {
        const b1: u32 = in.block[12];
        if (b1 == 0) {
            return null;
        }
        const b: u32 = entry(mnt, b1, idx);
        return if (b == 0) null else b;
    }
    idx -= per;
    if (idx < per * per) {
        const b1: u32 = in.block[13];
        if (b1 == 0) {
            return null;
        }
        const b2: u32 = entry(mnt, b1, idx / per);
        if (b2 == 0) {
            return null;
        }
        const b: u32 = entry(mnt, b2, idx % per);
        return if (b == 0) null else b;
    }
    return null;
}

/// Copy up to `buf.len` bytes of a regular file at `offset`; returns the count.
/// A hole (a zero block pointer) reads as zeroes, so sparse files are handled.
pub fn readData(mnt: *const Ext2Mount, in: *const Inode, offset: u64, buf: []u8) usize {
    if (offset >= in.size) {
        return 0;
    }
    var want: usize = buf.len;
    if (offset + want > in.size) {
        want = @intCast(in.size - offset);
    }

    var done: usize = 0;
    while (done < want) {
        const pos: u64 = offset + done;
        const lbn: u64 = pos / mnt.block_size;
        const boff: u64 = pos % mnt.block_size;
        var n: u64 = mnt.block_size - boff;
        if (n > want - done) {
            n = want - done;
        }

        if (bmap(mnt, in, lbn)) |bno| {
            const base: u64 = bno * mnt.block_size + boff;
            if (base >= mnt.image.len) {
                break;
            }
            if (base + n > mnt.image.len) {
                n = mnt.image.len - base;
            }
            var k: usize = 0;
            while (k < n) : (k += 1) {
                buf[done + k] = mnt.image[base + k];
            }
        } else {
            // A hole reads as zeroes.
            var k: usize = 0;
            while (k < n) : (k += 1) {
                buf[done + k] = 0;
            }
        }
        done += @intCast(n);
    }
    return done;
}

/// Read a symbolic link's target into `buf`; returns its length, or -1 when
/// there is no room.
pub fn readLink(mnt: *const Ext2Mount, in: *const Inode, buf: []u8) isize {
    if (in.size == 0 or in.size > buf.len) {
        return -1;
    }
    if (in.size < 60) {
        // The target is stored inline in the block pointer array.
        const src: []const u8 = @as([*]const u8, @ptrCast(&in.block))[0..@intCast(in.size)];
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            buf[i] = src[i];
        }
        return @intCast(in.size);
    }
    return @intCast(readData(mnt, in, 0, buf[0..@intCast(in.size)]));
}

// -- directories --------------------------------------------------------------

/// One directory entry returned by `dirNext`.
pub const DirEntry = struct {
    ino: u64,
    ftype: u8,
    name: [256]u8,
    name_len: usize,
};

/// Return the next live entry of directory `dir` at or after `pos.*`, advancing
/// `pos.*` past it. Returns false at the end of the directory.
pub fn dirNext(mnt: *const Ext2Mount, dir: *const Inode, pos: *u64, out: *DirEntry) bool {
    while (pos.* < dir.size) {
        const bno: u64 = bmap(mnt, dir, pos.* / mnt.block_size) orelse return false;
        const e: u64 = bno * mnt.block_size + (pos.* % mnt.block_size);
        const ino: u32 = rd32(mnt.image, e);
        const rec_len: u16 = rd16(mnt.image, e + 4);
        if (rec_len < 8 or (pos.* % mnt.block_size) + rec_len > mnt.block_size) {
            return false;
        }
        const nl: usize = mnt.image[e + 6];
        if (ino != 0 and nl > 0 and nl <= out.name.len and e + 8 + nl <= mnt.image.len) {
            var i: usize = 0;
            while (i < nl) : (i += 1) {
                out.name[i] = mnt.image[e + 8 + i];
            }
            out.ino = ino;
            out.ftype = mnt.image[e + 7];
            out.name_len = nl;
            pos.* += rec_len;
            return true;
        }
        pos.* += rec_len;
    }
    return false;
}

/// Find `name` in directory `dir`; returns its inode number, or null.
pub fn dirLookup(mnt: *const Ext2Mount, dir: *const Inode, name: []const u8) ?u64 {
    if ((dir.mode & S_IFMT) != S_IFDIR) {
        return null;
    }
    var pos: u64 = 0;
    while (pos < dir.size) {
        const bno: u64 = bmap(mnt, dir, pos / mnt.block_size) orelse return null;
        const e: u64 = bno * mnt.block_size + (pos % mnt.block_size);
        const ino: u32 = rd32(mnt.image, e);
        const rec_len: u16 = rd16(mnt.image, e + 4);
        if (rec_len < 8 or (pos % mnt.block_size) + rec_len > mnt.block_size) {
            return null;
        }
        const name_len: usize = mnt.image[e + 6];
        if (ino != 0 and name_len == name.len and e + 8 + name.len <= mnt.image.len) {
            var i: usize = 0;
            var same: bool = true;
            while (i < name.len) : (i += 1) {
                if (mnt.image[e + 8 + i] != name[i]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                return ino;
            }
        }
        pos += rec_len;
    }
    return null;
}
