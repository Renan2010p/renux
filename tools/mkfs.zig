// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// mkfs -- make an ext2 filesystem, in Zig.
//
// The Zig counterpart of the mke2fs calls the build made. It writes a rev-1
// ext2 filesystem with the features Renux needs (ext_attr, filetype,
// sparse_super, large_file): the superblock and its sparse_super backups, the
// group descriptors, the block and inode bitmaps, the inode tables, and, with
// -d, a whole directory tree (regular files, directories and symlinks).
//
// Usage:
//   mkfs [-b N] [-I N] [-m PCT] [-i BYTES] [-L LABEL] [-U UUID] [-d DIR] \
//        <image> [blocks]
//
// With -d the contents of DIR become the root of the new filesystem (like
// mke2fs -d). Every timestamp is the same fixed value, so the image is
// byte-for-byte reproducible. It is also the formatter the installer will run
// on the target partition.

const std: type = @import("std");
const Io: type = std.Io;
const Allocator: type = std.mem.Allocator;

/// The fixed timestamp (2001-09-08 22:46:40 UTC), for reproducible images.
const TIME: u32 = 1_000_000_000;

const S_IFREG: u16 = 0o100000;
const S_IFDIR: u16 = 0o040000;
const S_IFLNK: u16 = 0o120000;

const FT_REG: u8 = 1;
const FT_DIR: u8 = 2;
const FT_LNK: u8 = 7;

const Options = struct {
    bs: u32 = 1024,
    inode_size: u32 = 256,
    reserved_pct: u32 = 5,
    bytes_per_inode: u32 = 16384,
    label: []const u8 = "",
    dir: ?[]const u8 = null,
    image: []const u8 = "",
    blocks: ?u64 = null,
};

const Inode = struct {
    mode: u16 = 0,
    size: u64 = 0,
    links: u16 = 1,
    blocks: u32 = 0,
    block: [15]u32 = @splat(0),
};

const Ent = struct { ino: u32, ftype: u8, name: []const u8 };

const Fs = struct {
    io: Io,
    file: Io.File,
    a: Allocator,
    bs: u32,
    inode_size: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_table_blocks: u32,
    gd_blocks: u32,
    groups: u32,
    first_data_block: u32,
    total_blocks: u64,
    inodes_count: u32,
    reserved_blocks: u32,
    label: []const u8,
    used_blocks: []u8,
    used_inodes: []u8,
    inode_table: []u8,
    free_blocks: u64,
    free_inodes: u32,
    dirs: u32,
    dirs_pg: []u32,
    next_inode: u32,
    hint: u64,

    fn blockUsed(self: *Fs, blk: u64) bool {
        const i: usize = @intCast(blk);
        return (self.used_blocks[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
    }
    fn setBlock(self: *Fs, blk: u64, used: bool) void {
        const i: usize = @intCast(blk);
        const bit: u8 = @as(u8, 1) << @intCast(i & 7);
        if (used) self.used_blocks[i >> 3] |= bit else self.used_blocks[i >> 3] &= ~bit;
    }
    fn inodeUsed(self: *Fs, ino: u32) bool {
        const i: usize = ino - 1;
        return (self.used_inodes[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
    }
    fn setInode(self: *Fs, ino: u32, used: bool) void {
        const i: usize = ino - 1;
        const bit: u8 = @as(u8, 1) << @intCast(i & 7);
        if (used) self.used_inodes[i >> 3] |= bit else self.used_inodes[i >> 3] &= ~bit;
    }

    fn allocBlock(self: *Fs) u32 {
        const span: u64 = self.total_blocks - self.first_data_block;
        var b: u64 = self.hint;
        var scanned: u64 = 0;
        while (scanned < span) : (scanned += 1) {
            if (b >= self.total_blocks) b = self.first_data_block;
            if (!self.blockUsed(b)) {
                self.setBlock(b, true);
                self.free_blocks -= 1;
                self.hint = b + 1;
                return @intCast(b);
            }
            b += 1;
        }
        std.process.fatal("mkfs: out of blocks (total={d} hint={d} scan={d})", .{ self.total_blocks, self.hint, scanned });
    }

    fn allocInode(self: *Fs) u32 {
        while (self.next_inode < self.inodes_count) {
            const ino = self.next_inode;
            self.next_inode += 1;
            if (!self.inodeUsed(ino)) {
                self.setInode(ino, true);
                self.free_inodes -= 1;
                return ino;
            }
        }
        std.process.fatal("mkfs: out of inodes", .{});
    }

    fn writeAt(self: *Fs, buf: []const u8, off: u64) void {
        _ = self.file.writePositional(self.io, &.{buf}, off) catch {};
    }
    fn writeBlock(self: *Fs, blk: u32, buf: []const u8) void {
        self.writeAt(buf, @as(u64, blk) * self.bs);
    }
    fn ptrs(self: *Fs) usize {
        return self.bs / 4;
    }
    fn noteDir(self: *Fs, ino: u32) void {
        self.dirs_pg[(ino - 1) / self.inodes_per_group] += 1;
        self.dirs += 1;
    }
    fn inodeOffset(self: *Fs, ino: u32) usize {
        const g: u32 = (ino - 1) / self.inodes_per_group;
        const j: u32 = (ino - 1) % self.inodes_per_group;
        return @as(usize, g) * self.inode_table_blocks * self.bs + @as(usize, j) * self.inode_size;
    }
};

fn log2(v: u32) u32 {
    var n: u32 = 0;
    var x: u32 = v;
    while (x > 1) : (x >>= 1) n += 1;
    return n;
}
fn roundUp(v: u64, a: u64) u64 {
    return (v + a - 1) / a * a;
}
fn put16(b: []u8, off: usize, v: u16) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
}
fn put32(b: []u8, off: usize, v: u32) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
    b[off + 2] = @truncate(v >> 16);
    b[off + 3] = @truncate(v >> 24);
}

fn isPowerOf(g: u32, base: u32) bool {
    if (g == 0) return false;
    var x: u32 = g;
    while (x % base == 0 and x > 1) x /= base;
    return x == 1;
}
fn hasSuper(g: u32) bool {
    return g == 0 or isPowerOf(g, 3) or isPowerOf(g, 5) or isPowerOf(g, 7);
}
fn groupStart(fs: *const Fs, g: u32) u64 {
    return @as(u64, fs.first_data_block) + @as(u64, g) * fs.blocks_per_group;
}

const Meta = struct { bitmap: u32, imap: u32, itable: u32, data: u64, end: u64 };
fn groupMeta(fs: *const Fs, g: u32) Meta {
    const base: u64 = groupStart(fs, g);
    var b: u64 = base;
    if (hasSuper(g)) b += 1 + fs.gd_blocks;
    const bitmap: u32 = @intCast(b);
    const imap: u32 = @intCast(b + 1);
    const itable: u32 = @intCast(b + 2);
    return .{
        .bitmap = bitmap,
        .imap = imap,
        .itable = itable,
        .data = b + 2 + fs.inode_table_blocks,
        .end = @min(base + fs.blocks_per_group, fs.total_blocks),
    };
}

// -- inodes and data ---------------------------------------------------------

fn writeIndirect(fs: *Fs, level: u32, blocks: []const u32, inode: *Inode) u32 {
    const blk: u32 = fs.allocBlock();
    const buf: []u8 = try_alloc(fs, fs.bs);
    defer fs.a.free(buf);
    @memset(buf, 0);
    const ptrs: usize = fs.ptrs();
    if (level == 1) {
        var i: usize = 0;
        while (i < ptrs and i < blocks.len) : (i += 1) put32(buf, i * 4, blocks[i]);
    } else {
        const span: usize = intPow(ptrs, level - 1);
        var i: usize = 0;
        var off: usize = 0;
        while (i < ptrs and off < blocks.len) : (i += 1) {
            put32(buf, i * 4, writeIndirect(fs, level - 1, blocks[off..], inode));
            off += @min(span, blocks.len - off);
        }
    }
    fs.writeBlock(blk, buf);
    inode.blocks += fs.bs / 512;
    return blk;
}

fn intPow(base: usize, exp: u32) usize {
    var r: usize = 1;
    var i: u32 = 0;
    while (i < exp) : (i += 1) r *= base;
    return r;
}

fn try_alloc(fs: *Fs, n: usize) []u8 {
    return fs.a.alloc(u8, n) catch std.process.fatal("mkfs: out of memory", .{});
}

/// Allocate the data blocks of `content` and fill `inode`'s pointer tree.
fn storeData(fs: *Fs, inode: *Inode, content: []const u8) void {
    const n: usize = (content.len + fs.bs - 1) / fs.bs;
    if (n == 0) return;
    const blocks: []u32 = fs.a.alloc(u32, n) catch std.process.fatal("mkfs: out of memory", .{});
    defer fs.a.free(blocks);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const blk: u32 = fs.allocBlock();
        blocks[i] = blk;
        const bs: usize = fs.bs;
        const off: usize = i * bs;
        fs.writeBlock(blk, content[off..@min(off + bs, content.len)]);
    }
    inode.blocks += @intCast(n * (fs.bs / 512));

    const ptrs: usize = fs.ptrs();
    var off: usize = 0;
    var k: usize = 0;
    while (k < 12 and off < n) : (k += 1) {
        inode.block[k] = blocks[off];
        off += 1;
    }
    if (off < n) {
        inode.block[12] = writeIndirect(fs, 1, blocks[off..], inode);
        off += @min(ptrs, n - off);
    }
    if (off < n) {
        inode.block[13] = writeIndirect(fs, 2, blocks[off..], inode);
        off += @min(ptrs * ptrs, n - off);
    }
    if (off < n) {
        inode.block[14] = writeIndirect(fs, 3, blocks[off..], inode);
    }
}

fn putInode(fs: *Fs, ino: u32, in: *const Inode) void {
    const off = fs.inodeOffset(ino);
    const b = fs.inode_table[off .. off + fs.inode_size];
    @memset(b, 0);
    put16(b, 0, in.mode);
    put32(b, 4, @truncate(in.size));
    put32(b, 8, TIME); // atime
    put32(b, 12, TIME); // ctime
    put32(b, 16, TIME); // mtime
    put16(b, 26, in.links);
    put32(b, 28, in.blocks);
    for (in.block, 0..) |blk, i| put32(b, 40 + i * 4, blk);
    put32(b, 108, @truncate(in.size >> 32));
}

/// A regular file: content, permissions.
fn makeFile(fs: *Fs, perms: u16, content: []const u8) u32 {
    const ino = fs.allocInode();
    var in: Inode = .{ .mode = S_IFREG | perms, .size = content.len, .links = 1 };
    storeData(fs, &in, content);
    putInode(fs, ino, &in);
    return ino;
}

/// A symbolic link: fast (target in i_block) when short, else a data block.
fn makeSymlink(fs: *Fs, target: []const u8) u32 {
    const ino = fs.allocInode();
    var in: Inode = .{ .mode = S_IFLNK | 0o777, .size = target.len, .links = 1 };
    if (target.len < 60) {
        var i: usize = 0;
        while (i < target.len) : (i += 1) {
            in.block[i / 4] |= @as(u32, target[i]) << @intCast((i % 4) * 8);
        }
    } else {
        storeData(fs, &in, target);
    }
    putInode(fs, ino, &in);
    return ino;
}

/// An empty directory holding only "." and "..".
fn makeDir(fs: *Fs, self_ino: u32, parent_ino: u32, perms: u16) void {
    var entries = [_]Ent{
        .{ .ino = self_ino, .ftype = FT_DIR, .name = "." },
        .{ .ino = parent_ino, .ftype = FT_DIR, .name = ".." },
    };
    const content = dirContent(fs, &entries);
    var in: Inode = .{ .mode = S_IFDIR | perms, .size = content.len, .links = 2 };
    storeData(fs, &in, content);
    fs.a.free(content);
    putInode(fs, self_ino, &in);
    fs.noteDir(self_ino);
}

/// Lay `entries` into blocks: each entry's rec_len reaches the next one, and
/// the last entry of a block spans to the end of the block.
fn dirContent(fs: *Fs, entries: []const Ent) []u8 {
    const bs: usize = fs.bs;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < entries.len) {
        const block_start: usize = list.items.len;
        var last_off: usize = 0;
        var placed: bool = false;
        while (i < entries.len) {
            const e = entries[i];
            const need: usize = (8 + e.name.len + 3) & ~@as(usize, 3);
            const used: usize = list.items.len - block_start;
            if (used + need > bs) break;
            last_off = list.items.len;
            var ent: [8]u8 = undefined;
            put32(&ent, 0, e.ino);
            put16(&ent, 4, @intCast(need));
            ent[6] = @intCast(e.name.len);
            ent[7] = e.ftype;
            list.appendSlice(fs.a, &ent) catch {};
            list.appendSlice(fs.a, e.name) catch {};
            var pad: usize = need - 8 - e.name.len;
            while (pad > 0) : (pad -= 1) list.append(fs.a, 0) catch {};
            i += 1;
            placed = true;
        }
        if (!placed) std.process.fatal("mkfs: directory name too long", .{});
        const grow: usize = block_start + bs - list.items.len;
        const cur: u16 = @intCast(@as(usize, list.items[last_off + 4]) | (@as(usize, list.items[last_off + 5]) << 8));
        put16(list.items, last_off + 4, cur + @as(u16, @intCast(grow)));
        var pad2: usize = grow;
        while (pad2 > 0) : (pad2 -= 1) list.append(fs.a, 0) catch {};
    }
    return list.toOwnedSlice(fs.a) catch unreachable;
}

// -- populating from a directory ---------------------------------------------

fn populate(fs: *Fs, src: Io.Dir, dir_ino: u32, parent_ino: u32, arena: Allocator) void {
    fs.noteDir(dir_ino);
    var entries: std.ArrayListUnmanaged(Ent) = .empty;
    entries.append(arena, .{ .ino = dir_ino, .ftype = FT_DIR, .name = "." }) catch {};
    entries.append(arena, .{ .ino = parent_ino, .ftype = FT_DIR, .name = ".." }) catch {};
    var subdirs: u16 = 0;

    var it = src.iterate();
    while (it.next(fs.io) catch null) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        // statFile follows symlinks; the directory entry's kind does not, so
        // a symlink is read as a symlink (not as a copy of its target).
        if (e.kind == .sym_link) {
            var lbuf: [4096]u8 = undefined;
            const n = src.readLink(fs.io, e.name, &lbuf) catch continue;
            const child = makeSymlink(fs, lbuf[0..n]);
            entries.append(arena, .{ .ino = child, .ftype = FT_LNK, .name = arena.dupe(u8, e.name) catch e.name }) catch {};
            continue;
        }
        const st = src.statFile(fs.io, e.name, .{}) catch continue;
        switch (st.kind) {
            .directory => {
                const child = fs.allocInode();
                entries.append(arena, .{ .ino = child, .ftype = FT_DIR, .name = arena.dupe(u8, e.name) catch e.name }) catch {};
                subdirs += 1;
                var sub = src.openDir(fs.io, e.name, .{ .iterate = true }) catch continue;
                defer sub.close(fs.io);
                populate(fs, sub, child, dir_ino, arena);
            },
            .file => {
                const content = src.readFileAlloc(fs.io, e.name, fs.a, .unlimited) catch continue;
                defer fs.a.free(content);
                const child = makeFile(fs, permsOf(st), content);
                entries.append(arena, .{ .ino = child, .ftype = FT_REG, .name = arena.dupe(u8, e.name) catch e.name }) catch {};
            },
            else => {},
        }
    }

    // lost+found belongs to the root, as mke2fs makes it.
    if (dir_ino == 2) {
        entries.append(arena, .{ .ino = 11, .ftype = FT_DIR, .name = "lost+found" }) catch {};
        subdirs += 1;
    }

    const content = dirContent(fs, entries.items);
    var in: Inode = .{ .mode = S_IFDIR | 0o755, .size = content.len, .links = 2 + subdirs };
    storeData(fs, &in, content);
    fs.a.free(content);
    putInode(fs, dir_ino, &in);
}

fn permsOf(st: Io.File.Stat) u16 {
    const m: u32 = @backingInt(st.permissions);
    return @truncate(m & 0o7777);
}

fn openImage(io: Io, cwd: Io.Dir, path: []const u8) Io.File {
    if (cwd.statFile(io, path, .{})) |_| {
        return cwd.openFile(io, path, .{ .mode = .read_write }) catch
            std.process.fatal("mkfs: cannot open {s}", .{path});
    } else |_| {
        return cwd.createFile(io, path, .{}) catch
            std.process.fatal("mkfs: cannot create {s}", .{path});
    }
}

// -- superblock and group descriptors ----------------------------------------

fn writeSuperAndGd(fs: *Fs, g: u32) void {
    var sb: [1024]u8 = @splat(0);
    const sbl: []u8 = &sb;
    put32(&sb, 0, fs.inodes_count);
    put32(&sb, 4, @intCast(fs.total_blocks));
    put32(&sb, 8, fs.reserved_blocks);
    put32(&sb, 12, @intCast(fs.free_blocks));
    put32(&sb, 16, fs.free_inodes);
    put32(&sb, 20, fs.first_data_block);
    put32(&sb, 24, log2(fs.bs / 1024));
    put32(&sb, 28, log2(fs.bs / 1024));
    put32(&sb, 32, fs.blocks_per_group);
    put32(&sb, 36, fs.blocks_per_group);
    put32(&sb, 40, fs.inodes_per_group);
    put32(&sb, 44, TIME); // mtime
    put32(&sb, 48, TIME); // wtime
    put16(&sb, 52, 0); // mnt_count
    put16(&sb, 54, 0xFFFF); // max_mnt_count (-1)
    put16(&sb, 56, 0xEF53); // magic
    put16(&sb, 58, 1); // state: clean
    put16(&sb, 60, 1); // errors: continue
    put32(&sb, 64, TIME); // lastcheck
    put32(&sb, 72, 0); // creator os: linux
    put32(&sb, 76, 1); // rev level
    put16(&sb, 84, 11); // first_ino
    put16(&sb, 88, @intCast(fs.inode_size));
    put32(&sb, 92, 0x0008); // feature_compat: ext_attr
    put32(&sb, 96, 0x0002); // feature_incompat: filetype
    put32(&sb, 100, 0x0003); // feature_ro_compat: sparse_super | large_file
    const ln: usize = @min(fs.label.len, 16);
    @memcpy(sbl[120 .. 120 + ln], fs.label[0..ln]);
    put32(&sb, 264, TIME); // mkfs time

    const gd: []u8 = try_alloc(fs, fs.gd_blocks * fs.bs);
    defer fs.a.free(gd);
    @memset(gd, 0);
    var i: u32 = 0;
    while (i < fs.groups) : (i += 1) {
        const m = groupMeta(fs, i);
        const off: usize = @as(usize, i) * 32;
        put32(gd, off + 0, m.bitmap);
        put32(gd, off + 4, m.imap);
        put32(gd, off + 8, m.itable);
        put16(gd, off + 12, @intCast(groupFreeBlocks(fs, i)));
        put16(gd, off + 14, @intCast(groupFreeInodes(fs, i)));
        put16(gd, off + 16, @intCast(fs.dirs_pg[i]));
    }

    if (g == 0) {
        // The primary superblock is always at byte 1024; the descriptors
        // follow it in the next block.
        fs.writeAt(&sb, 1024);
        fs.writeAt(gd, @as(u64, fs.first_data_block + 1) * fs.bs);
    } else {
        const base: u64 = groupStart(fs, g) * fs.bs;
        fs.writeAt(&sb, base);
        fs.writeAt(gd, base + fs.bs);
    }
}

fn countFreeBlocks(fs: *Fs) u64 {
    var fre: u64 = 0;
    var b: u64 = fs.first_data_block;
    while (b < fs.total_blocks) : (b += 1) {
        if (!fs.blockUsed(b)) fre += 1;
    }
    return fre;
}

fn countFreeInodes(fs: *Fs) u32 {
    var fre: u32 = 0;
    var ino: u32 = 1;
    while (ino <= fs.inodes_count) : (ino += 1) {
        if (!fs.inodeUsed(ino)) fre += 1;
    }
    return fre;
}

fn groupFreeBlocks(fs: *Fs, g: u32) u64 {
    const m = groupMeta(fs, g);
    var fre: u64 = 0;
    var b: u64 = m.data;
    while (b < m.end) : (b += 1) {
        if (!fs.blockUsed(b)) fre += 1;
    }
    return fre;
}

fn groupFreeInodes(fs: *Fs, g: u32) u64 {
    var fre: u64 = 0;
    var ino: u32 = g * fs.inodes_per_group + 1;
    const end: u32 = @min(ino + fs.inodes_per_group, fs.inodes_count + 1);
    while (ino < end) : (ino += 1) {
        if (!fs.inodeUsed(ino)) fre += 1;
    }
    return fre;
}

fn writeBitmaps(fs: *Fs) void {
    const buf: []u8 = try_alloc(fs, fs.bs);
    defer fs.a.free(buf);
    var g: u32 = 0;
    while (g < fs.groups) : (g += 1) {
        const m = groupMeta(fs, g);
        // Block bitmap.
        @memset(buf, 0);
        const base: u64 = groupStart(fs, g);
        var b: u64 = base;
        while (b < base + fs.blocks_per_group) : (b += 1) {
            const used: bool = b >= fs.total_blocks or fs.blockUsed(b);
            if (used) {
                const i: usize = @intCast(b - base);
                buf[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
            }
        }
        fs.writeBlock(m.bitmap, buf);
        // Inode bitmap: bits past the last inode stay set, as e2fsck wants.
        @memset(buf, 0xFF);
        const ipg: u32 = fs.inodes_per_group;
        var j: u32 = 0;
        while (j < ipg) : (j += 1) {
            const ino: u32 = g * ipg + j + 1;
            if (ino <= fs.inodes_count and !fs.inodeUsed(ino)) {
                buf[j >> 3] &= ~(@as(u8, 1) << @intCast(j & 7));
            }
        }
        fs.writeBlock(m.imap, buf);
    }
}

fn writeInodeTables(fs: *Fs) void {
    var g: u32 = 0;
    while (g < fs.groups) : (g += 1) {
        const m = groupMeta(fs, g);
        const off: usize = @as(usize, g) * fs.inode_table_blocks * fs.bs;
        const len: usize = fs.inode_table_blocks * fs.bs;
        fs.writeAt(fs.inode_table[off .. off + len], @as(u64, m.itable) * fs.bs);
    }
}

// -- main --------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const a: Allocator = init.arena.allocator();
    const io: Io = init.io;
    const args = try init.minimal.args.toSlice(a);

    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-b")) {
            i += 1;
            opts.bs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            opts.inode_size = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-m")) {
            i += 1;
            opts.reserved_pct = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-i")) {
            i += 1;
            opts.bytes_per_inode = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-L")) {
            i += 1;
            opts.label = args[i];
        } else if (std.mem.eql(u8, arg, "-U")) {
            i += 1; // UUID: only all-zero (the default) is meaningful here
        } else if (std.mem.eql(u8, arg, "-d")) {
            i += 1;
            opts.dir = args[i];
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "-t")) {
            i += 1; // features/type: fixed
        } else if (std.mem.eql(u8, arg, "-q")) {
            // quiet
        } else if (opts.image.len == 0) {
            opts.image = arg;
        } else {
            opts.blocks = try std.fmt.parseInt(u64, args[i], 10);
        }
    }
    if (opts.image.len == 0) std.process.fatal("usage: mkfs [-b N] [-I N] [-m PCT] [-i BYTES] [-L LABEL] [-U UUID] [-d DIR] <image> [blocks]", .{});

    try makeFs(io, std.heap.page_allocator, opts);
}

fn makeFs(io: Io, a: Allocator, opts: Options) !void {
    const cwd = Io.Dir.cwd();
    const total_blocks: u64 = opts.blocks orelse blk: {
        const st = cwd.statFile(io, opts.image, .{}) catch {
            std.process.fatal("mkfs: cannot stat {s}", .{opts.image});
        };
        break :blk st.size / opts.bs;
    };

    const blocks_per_group: u32 = opts.bs * 8;
    const first_data_block: u32 = if (opts.bs == 1024) 1 else 0;
    const groups: u32 = @intCast(roundUp(total_blocks - first_data_block, blocks_per_group) / blocks_per_group);
    var inodes_count: u32 = @intCast(@max(@as(u64, 16), roundUp(total_blocks * opts.bs / opts.bytes_per_inode, 1)));
    var inodes_per_group: u32 = @intCast(roundUp(roundUp(inodes_count, groups) / groups, 8));
    if (inodes_per_group == 0) inodes_per_group = 8;
    inodes_count = inodes_per_group * groups;
    const inode_table_blocks: u32 = @intCast(roundUp(@as(u64, inodes_per_group) * opts.inode_size, opts.bs) / opts.bs);
    const gd_blocks: u32 = @intCast(roundUp(@as(u64, groups) * 32, opts.bs) / opts.bs);

    const used_blocks = try a.alloc(u8, (@as(usize, @intCast(total_blocks)) + 7) / 8);
    const used_inodes = try a.alloc(u8, (@as(usize, inodes_count) + 7) / 8);
    const inode_table = try a.alloc(u8, @as(usize, groups) * inode_table_blocks * opts.bs);
    const dirs_pg = try a.alloc(u32, groups);
    @memset(used_blocks, 0);
    @memset(used_inodes, 0);
    @memset(inode_table, 0);
    @memset(dirs_pg, 0);

    const file = openImage(io, cwd, opts.image);
    defer file.close(io);
    file.setLength(io, total_blocks * opts.bs) catch {};

    var fs: Fs = .{
        .io = io,
        .file = file,
        .a = a,
        .bs = opts.bs,
        .inode_size = opts.inode_size,
        .blocks_per_group = blocks_per_group,
        .inodes_per_group = inodes_per_group,
        .inode_table_blocks = inode_table_blocks,
        .gd_blocks = gd_blocks,
        .groups = groups,
        .first_data_block = first_data_block,
        .total_blocks = total_blocks,
        .inodes_count = inodes_count,
        .reserved_blocks = @intCast(total_blocks * opts.reserved_pct / 100),
        .label = opts.label,
        .used_blocks = used_blocks,
        .used_inodes = used_inodes,
        .inode_table = inode_table,
        .free_blocks = total_blocks - first_data_block,
        .free_inodes = inodes_count,
        .dirs = 0,
        .dirs_pg = dirs_pg,
        .next_inode = 12,
        .hint = first_data_block,
    };

    // 1. Reserve each group's metadata.
    var g: u32 = 0;
    while (g < groups) : (g += 1) {
        const m = groupMeta(&fs, g);
        var b: u64 = groupStart(&fs, g);
        while (b < m.data) : (b += 1) {
            if (!fs.blockUsed(b)) {
                fs.setBlock(b, true);
                fs.free_blocks -= 1;
            }
        }
    }
    // Inodes 1..10 are reserved (inode 2 is the root).
    var ri: u32 = 1;
    while (ri <= 11) : (ri += 1) {
        if (!fs.inodeUsed(ri)) {
            fs.setInode(ri, true);
            fs.free_inodes -= 1;
        }
    }
    fs.next_inode = 12;

    // 2. Root directory (inode 2) and lost+found (inode 11).
    if (opts.dir) |dirpath| {
        var root = cwd.openDir(io, dirpath, .{ .iterate = true }) catch {
            std.process.fatal("mkfs: cannot open {s}", .{dirpath});
        };
        defer root.close(io);
        const arena = a;
        populate(&fs, root, 2, 2, arena);
        // Root's own inode was written by populate; add lost+found too.
    } else {
        // Empty root: just "." and "..".
        var d: Inode = .{ .mode = S_IFDIR | 0o755, .links = 2 + 1 };
        const content = dirContent(&fs, &.{
            .{ .ino = 2, .ftype = FT_DIR, .name = "." },
            .{ .ino = 2, .ftype = FT_DIR, .name = ".." },
            .{ .ino = 11, .ftype = FT_DIR, .name = "lost+found" },
        });
        d.size = content.len;
        storeData(&fs, &d, content);
        fs.a.free(content);
        putInode(&fs, 2, &d);
        fs.noteDir(2);
    }
    makeDir(&fs, 11, 2, 0o700);

    // 3. Write the bitmaps, inode tables and superblocks.
    fs.free_blocks = countFreeBlocks(&fs);
    fs.free_inodes = countFreeInodes(&fs);
    writeBitmaps(&fs);
    writeInodeTables(&fs);
    g = 0;
    while (g < groups) : (g += 1) {
        if (g == 0 or hasSuper(g)) writeSuperAndGd(&fs, g);
    }
}
