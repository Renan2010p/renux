// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// mkiso -- build the Renux UEFI boot ISO, in Zig.
//
// This replaces xorriso and the mtools (mkfs.fat, mmd, mcopy) that
// tools/mkiso.sh needed. A UEFI-only ISO requires just two things the
// firmware understands, and both are simple on-disk formats:
//
//   * a FAT16 image holding \EFI\BOOT\BOOTX64.EFI (the Renux loader),
//     \boot\kernel\kernel and \boot\defaults\loader.conf -- UEFI reads FAT,
//     not ISO 9660;
//   * an ISO 9660 volume whose El Torito boot catalog points the firmware at
//     that image (the "no emulation" boot, load LBA in 512-byte units).
//
// The ISO 9660 tree itself is therefore empty (just the root directory): the
// whole system rides inside the boot image. Everything is byte-for-byte
// reproducible -- fixed timestamps and volume id -- so an unchanged system
// produces an unchanged ISO, like the rest of the build.
//
// Usage: mkiso <kernel> <loader.efi> <loader.conf> <out.iso>

const std: type = @import("std");
const Io: type = std.Io;
const Allocator: type = std.mem.Allocator;

// -- FAT16 -------------------------------------------------------------------
//
// A FAT16 volume of 512-byte sectors and 4 KiB clusters. The three files and
// the five directories they live in are laid out by hand; every name fits the
// 8.3 form (uppercased), so no long-file-name entries are needed.

const FAT_SECTOR: usize = 512;
const SPC: usize = 8; // sectors per cluster (4 KiB)
const RESERVED: usize = 1;
const NFATS: usize = 2;
const ROOT_ENTRIES: usize = 512;
const ROOT_DIR_SECTORS: usize = ROOT_ENTRIES * 32 / FAT_SECTOR; // 32
const CLUSTER_BYTES: usize = SPC * FAT_SECTOR;
const FAT_LABEL: [11]u8 = .{ 'R', 'E', 'N', 'U', 'X', 'E', 'F', 'I', ' ', ' ', ' ' };

const ATTR_DIR: u8 = 0x10;
const ATTR_LABEL: u8 = 0x08;
const ATTR_ARCHIVE: u8 = 0x20;
const FAT_END: u16 = 0xFFFF;

fn clustersFor(size: usize) u16 {
    if (size == 0) return 0;
    return @intCast((size + CLUSTER_BYTES - 1) / CLUSTER_BYTES);
}

fn name83(dst: *[11]u8, s: []const u8) void {
    @memset(dst, ' ');
    var i: usize = 0;
    var base: usize = 0;
    while (i < s.len and s[i] != '.') : (i += 1) {
        if (base < 8) {
            dst[base] = std.ascii.toUpper(s[i]);
            base += 1;
        }
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var e: usize = 0;
        while (i < s.len) : (i += 1) {
            if (e < 3) {
                dst[8 + e] = std.ascii.toUpper(s[i]);
                e += 1;
            }
        }
    }
}

fn putDirent(buf: []u8, off: usize, name: [11]u8, attr: u8, cluster: u16, size: u32) void {
    const e = buf[off .. off + 32];
    @memset(e, 0);
    @memcpy(e[0..11], &name);
    e[11] = attr;
    // firstClusterHigh (offset 20) stays 0 on FAT16
    le16(e, 26, cluster);
    le32(e, 28, size);
}

/// Whether `name` fits the 8.3 form (one dot, short extension).
fn fits83(name: []const u8) bool {
    var i: usize = 0;
    var base: usize = 0;
    while (i < name.len and name[i] != '.') : (i += 1) base += 1;
    if (base == 0 or base > 8) return false;
    if (i == name.len) return true;
    i += 1;
    const ext: usize = name.len - i;
    if (ext == 0 or ext > 3) return false;
    var j: usize = i;
    while (j < name.len) : (j += 1) {
        if (name[j] == '.') return false;
    }
    return true;
}

/// Checksum of a short name, as VFAT long-name entries store it.
fn lfnChecksum(short: [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| sum = ((sum & 1) << 7) +% (sum >> 1) +% c;
    return sum;
}

fn lower83(c: u8) bool {
    return c == ' ' or c == '.' or c == '"' or c == '*' or c == '+' or c == ',' or
        c == '/' or c == ':' or c == ';' or c == '<' or c == '=' or c == '>' or
        c == '?' or c == '[' or c == '\\' or c == ']' or c == '|';
}

/// An 8.3 name for `long`: its first six valid characters, "~1", and the
/// first three of the extension.
fn shortName(dst: *[11]u8, long: []const u8) void {
    @memset(dst, ' ');
    var i: usize = 0;
    var b: usize = 0;
    while (i < long.len and long[i] != '.') : (i += 1) {
        if (b < 6 and !lower83(long[i])) {
            dst[b] = std.ascii.toUpper(long[i]);
            b += 1;
        }
    }
    dst[b] = '~';
    b += 1;
    if (b < 8) {
        dst[b] = '1';
        b += 1;
    }
    if (i < long.len) {
        i += 1;
        var e: usize = 0;
        while (i < long.len and e < 3) : (i += 1) {
            if (!lower83(long[i])) {
                dst[8 + e] = std.ascii.toUpper(long[i]);
                e += 1;
            }
        }
    }
}

/// Write a directory entry for `name`, adding VFAT long-name entries when it
/// does not fit 8.3. Returns the number of bytes written.
fn putEntry(buf: []u8, off: usize, name: []const u8, attr: u8, cluster: u16, size: u32) usize {
    if (fits83(name)) {
        var n: [11]u8 = undefined;
        name83(&n, name);
        putDirent(buf, off, n, attr, cluster, size);
        return 32;
    }

    var short: [11]u8 = undefined;
    shortName(&short, name);
    const sum: u8 = lfnChecksum(short);
    const nents: usize = (name.len + 12) / 13;
    const positions = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    var written: usize = 0;
    var k: usize = nents;
    while (k > 0) {
        k -= 1;
        const seq: u8 = @intCast(k + 1);
        const e = buf[off + written .. off + written + 32];
        @memset(e, 0);
        e[0] = if (k == nents - 1) seq | 0x40 else seq;
        e[11] = 0x0F; // long-name attribute
        e[12] = 0;
        e[13] = sum;
        var c: usize = 0;
        while (c < 13) : (c += 1) {
            const idx = k * 13 + c;
            const ch: u16 = if (idx < name.len) name[idx] else if (idx == name.len) 0 else 0xFFFF;
            e[positions[c]] = @truncate(ch);
            e[positions[c] + 1] = @truncate(ch >> 8);
        }
        written += 32;
    }
    putDirent(buf, off + written, short, attr, cluster, size);
    return written + 32;
}

/// A directory entry with the "." or ".." special name.
fn putDot(buf: []u8, off: usize, dots: []const u8, cluster: u16) void {
    var n: [11]u8 = undefined;
    @memset(&n, ' ');
    for (dots, 0..) |ch, i| n[i] = ch;
    putDirent(buf, off, n, ATTR_DIR, cluster, 0);
}

/// Build the FAT16 boot image holding the loader, kernel and loader.conf.
fn buildFat(a: Allocator, loader: []const u8, kernel: []const u8, conf: []const u8) ![]u8 {
    // Cluster assignment: five directories first, then the files.
    const efI: u16 = 2;
    const bootE: u16 = 3; // \EFI\BOOT
    const bootR: u16 = 4; // \boot
    const kernelD: u16 = 5; // \boot\kernel
    const defaultsD: u16 = 6; // \boot\defaults
    const loaderN = clustersFor(loader.len);
    const kernelN = clustersFor(kernel.len);
    const confN = clustersFor(conf.len);
    const loaderFirst: u16 = 7;
    const kernelFirst: u16 = loaderFirst + loaderN;
    const confFirst: u16 = kernelFirst + kernelN;
    const used: usize = @as(usize, confFirst) + confN - 2;
    // FAT16 is only recognised above 4085 clusters; pad the volume when the
    // payload is small (an unused cluster is simply marked free).
    const total_clusters: usize = if (used + 128 < 4085) 4085 else used + 128;
    if (total_clusters + 2 > 0xFFF0) return error.FatTooBig;

    const fat_size: usize = ((total_clusters + 2) * 2 + FAT_SECTOR - 1) / FAT_SECTOR;
    const data_sectors: usize = total_clusters * SPC;
    const total_sectors: usize = RESERVED + NFATS * fat_size + ROOT_DIR_SECTORS + data_sectors;
    const image = try a.alloc(u8, total_sectors * FAT_SECTOR);
    @memset(image, 0);

    // Boot parameter block.
    const bpb = image[0..FAT_SECTOR];
    bpb[0] = 0xEB;
    bpb[1] = 0x3C;
    bpb[2] = 0x90;
    @memcpy(bpb[3..11], "RENUX   ");
    le16(bpb, 11, FAT_SECTOR);
    bpb[13] = SPC;
    le16(bpb, 14, RESERVED);
    bpb[16] = NFATS;
    le16(bpb, 17, ROOT_ENTRIES);
    le16(bpb, 19, if (total_sectors <= 0xFFFF) @intCast(total_sectors) else 0);
    bpb[21] = 0xF8; // fixed disk
    le16(bpb, 22, @intCast(fat_size));
    le16(bpb, 24, 32); // sectors/track
    le16(bpb, 26, 2); // heads
    le32(bpb, 28, 0); // hidden sectors
    le32(bpb, 32, if (total_sectors > 0xFFFF) @intCast(total_sectors) else 0);
    bpb[36] = 0x80;
    bpb[38] = 0x29;
    le32(bpb, 39, 0x52454E58); // volume id "RENX"
    @memcpy(bpb[43..54], &FAT_LABEL);
    @memcpy(bpb[54..62], "FAT16   ");
    bpb[510] = 0x55;
    bpb[511] = 0xAA;

    // The two FATs: FAT[0]/FAT[1] are the media descriptor and end marker.
    const fat1 = image[RESERVED * FAT_SECTOR ..][0 .. fat_size * FAT_SECTOR];
    const fat2 = image[(RESERVED + fat_size) * FAT_SECTOR ..][0 .. fat_size * FAT_SECTOR];
    fat1[0] = 0xF8;
    fat1[1] = 0xFF;
    fat1[2] = 0xFF;
    fat1[3] = 0xFF;
    const setFat = struct {
        fn f(fat: []u8, c: u16, v: u16) void {
            le16(fat, @as(usize, c) * 2, v);
        }
    }.f;
    // Directories are single clusters; files are laid out contiguously.
    inline for (.{ efI, bootE, bootR, kernelD, defaultsD }) |d| setFat(fat1, d, FAT_END);
    var c: u16 = loaderFirst;
    var k: u16 = 0;
    while (k < loaderN) : (k += 1) {
        setFat(fat1, c, if (k + 1 == loaderN) FAT_END else c + 1);
        c += 1;
    }
    k = 0;
    while (k < kernelN) : (k += 1) {
        setFat(fat1, c, if (k + 1 == kernelN) FAT_END else c + 1);
        c += 1;
    }
    k = 0;
    while (k < confN) : (k += 1) {
        setFat(fat1, c, if (k + 1 == confN) FAT_END else c + 1);
        c += 1;
    }
    @memcpy(fat2, fat1);

    const root = image[(RESERVED + NFATS * fat_size) * FAT_SECTOR ..][0 .. ROOT_DIR_SECTORS * FAT_SECTOR];
    var off: usize = 0;
    off += putEntry(root, off, "RENUXEFI", ATTR_LABEL, 0, 0);
    off += putEntry(root, off, "EFI", ATTR_DIR, efI, 0);
    _ = putEntry(root, off, "boot", ATTR_DIR, bootR, 0);

    const data_start: usize = (RESERVED + NFATS * fat_size + ROOT_DIR_SECTORS) * FAT_SECTOR;
    const clusterOff = struct {
        fn f(base_off: usize, base: u16) usize {
            return base_off + @as(usize, base - 2) * CLUSTER_BYTES;
        }
    }.f;

    const dirEfi = image[clusterOff(data_start, efI)..][0..CLUSTER_BYTES];
    putDot(dirEfi, 0, ".", efI);
    putDot(dirEfi, 32, "..", 0);
    off = 64;
    _ = putEntry(dirEfi, off, "BOOT", ATTR_DIR, bootE, 0);

    const dirEfiBoot = image[clusterOff(data_start, bootE)..][0..CLUSTER_BYTES];
    putDot(dirEfiBoot, 0, ".", bootE);
    putDot(dirEfiBoot, 32, "..", efI);
    off = 64;
    _ = putEntry(dirEfiBoot, off, "BOOTX64.EFI", ATTR_ARCHIVE, loaderFirst, @intCast(loader.len));

    const dirBoot = image[clusterOff(data_start, bootR)..][0..CLUSTER_BYTES];
    putDot(dirBoot, 0, ".", bootR);
    putDot(dirBoot, 32, "..", 0);
    off = 64;
    off += putEntry(dirBoot, off, "kernel", ATTR_DIR, kernelD, 0);
    _ = putEntry(dirBoot, off, "defaults", ATTR_DIR, defaultsD, 0);

    const dirKernel = image[clusterOff(data_start, kernelD)..][0..CLUSTER_BYTES];
    putDot(dirKernel, 0, ".", kernelD);
    putDot(dirKernel, 32, "..", bootR);
    off = 64;
    _ = putEntry(dirKernel, off, "kernel", ATTR_ARCHIVE, kernelFirst, @intCast(kernel.len));

    const dirDefaults = image[clusterOff(data_start, defaultsD)..][0..CLUSTER_BYTES];
    putDot(dirDefaults, 0, ".", defaultsD);
    putDot(dirDefaults, 32, "..", bootR);
    off = 64;
    _ = putEntry(dirDefaults, off, "loader.conf", ATTR_ARCHIVE, confFirst, @intCast(conf.len));

    @memcpy(image[clusterOff(data_start, loaderFirst)..][0..loader.len], loader);
    @memcpy(image[clusterOff(data_start, kernelFirst)..][0..kernel.len], kernel);
    @memcpy(image[clusterOff(data_start, confFirst)..][0..conf.len], conf);
    return image;
}

// -- ISO 9660 + El Torito ----------------------------------------------------
//
// A minimal ISO 9660 volume: system area, a primary volume descriptor, the El
// Torito boot record, a terminator, the path tables, the boot catalog and the
// root directory, then the FAT image. The boot catalog uses the form xorriso
// emits for a UEFI-only disc: a validation entry with platform 0xEF followed
// by one default entry that loads the FAT image with no emulation.

const ISO_SECTOR: usize = 2048;
const ROOT_LBA: u32 = 22;
const CATALOG_LBA: u32 = 21;

fn le16(b: []u8, off: usize, v: u16) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
}
fn le32(b: []u8, off: usize, v: u32) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
    b[off + 2] = @truncate(v >> 16);
    b[off + 3] = @truncate(v >> 24);
}
fn be32(b: []u8, off: usize, v: u32) void {
    b[off] = @truncate(v >> 24);
    b[off + 1] = @truncate(v >> 16);
    b[off + 2] = @truncate(v >> 8);
    b[off + 3] = @truncate(v);
}
/// ISO 9660 stores 32-bit fields little-endian and then big-endian.
fn both32(b: []u8, off: usize, v: u32) void {
    le32(b, off, v);
    be32(b, off + 4, v);
}
fn both16(b: []u8, off: usize, v: u16) void {
    le16(b, off, v);
    b[off + 2] = @truncate(v >> 8);
    b[off + 3] = @truncate(v);
}

/// A fixed recording date (2001-09-08 22:46:40 UTC) keeps the ISO reproducible.
const DATE7: [7]u8 = .{ 101, 9, 8, 22, 46, 40, 0 };

fn putDirRecord(b: []u8, off: usize, extent: u32, len: u32, name: []const u8, is_dir: bool) usize {
    const pad: usize = if (name.len % 2 == 0) 1 else 0;
    const rec_len: usize = 33 + name.len + pad;
    const r = b[off .. off + rec_len];
    @memset(r, 0);
    r[0] = @intCast(rec_len);
    both32(r, 2, extent);
    both32(r, 10, len);
    @memcpy(r[18..25], &DATE7);
    r[25] = if (is_dir) 0x02 else 0x00;
    both16(r, 28, 1);
    r[32] = @intCast(name.len);
    @memcpy(r[33 .. 33 + name.len], name);
    return rec_len;
}

fn buildIso(a: Allocator, fat: []const u8) ![]u8 {
    const fat_sectors: usize = (fat.len + ISO_SECTOR - 1) / ISO_SECTOR;
    const first_data: usize = 32; // keep the image 2 KiB aligned
    const total_sectors: usize = first_data + fat_sectors;
    const iso = try a.alloc(u8, total_sectors * ISO_SECTOR);
    @memset(iso, 0);

    const sector = struct {
        fn s(buf: []u8, n: usize) []u8 {
            return buf[n * ISO_SECTOR ..][0..ISO_SECTOR];
        }
    }.s;

    // Primary Volume Descriptor.
    const pvd = sector(iso, 16);
    pvd[0] = 1;
    @memcpy(pvd[1..6], "CD001");
    pvd[6] = 1;
    @memset(pvd[8..40], ' ');
    @memset(pvd[40..72], ' ');
    @memcpy(pvd[40..45], "RENUX");
    both32(pvd, 80, @intCast(total_sectors));
    both16(pvd, 120, 1);
    both16(pvd, 124, 1);
    both16(pvd, 128, ISO_SECTOR);
    both32(pvd, 132, 10); // path table size
    le32(pvd, 140, 19); // L path table
    be32(pvd, 148, 20); // M path table
    _ = putDirRecord(pvd, 156, ROOT_LBA, ISO_SECTOR, &.{0}, true);
    @memset(pvd[190..318], ' ');
    @memset(pvd[318..446], ' ');
    @memset(pvd[446..574], ' ');
    @memset(pvd[574..702], ' ');
    @memcpy(pvd[574..579], "RENUX");
    @memset(pvd[702..739], ' ');
    @memset(pvd[739..776], ' ');
    @memset(pvd[776..813], ' ');
    const vdate: [17]u8 = .{ '2', '0', '0', '1', '0', '9', '0', '8', '2', '2', '4', '6', '4', '0', '0', '0', 0 };
    @memcpy(pvd[813..830], &vdate);
    @memcpy(pvd[830..847], &vdate);
    @memset(pvd[847..864], '0');
    @memcpy(pvd[864..881], &vdate);
    pvd[881] = 1;

    // El Torito boot record.
    const br = sector(iso, 17);
    br[0] = 0;
    @memcpy(br[1..6], "CD001");
    br[6] = 1;
    @memcpy(br[7..30], "EL TORITO SPECIFICATION");
    le32(br, 71, CATALOG_LBA);

    // Volume descriptor set terminator.
    const term = sector(iso, 18);
    term[0] = 255;
    @memcpy(term[1..6], "CD001");
    term[6] = 1;

    // Path tables (root only): length 10 bytes.
    const lpath = sector(iso, 19);
    lpath[0] = 1; // name length of the root
    le32(lpath, 2, ROOT_LBA);
    le16(lpath, 6, 1);
    const mpath = sector(iso, 20);
    mpath[0] = 1;
    be32(mpath, 2, ROOT_LBA);
    mpath[6] = 0;
    mpath[7] = 1;

    // Boot catalog: validation entry (platform x86), then an EFI section
    // header (platform 0xEF) with one entry, as a hybrid BIOS/UEFI disc does.
    //
    // The entry's load LBA is in 2048-byte blocks, not 512: both edk2's
    // PartitionDxe (ElTorito.c: Lba * (SIZE_2KB / BlockSize)) and libisofs
    // read it that way, and xorriso writes it that way (the efi.img of a
    // xorriso ISO sits at LBA 0x23 = 35 * 2048).
    const cat = sector(iso, CATALOG_LBA);
    const efi_lba: u32 = @intCast(first_data);
    const efi_count: u16 = if (fat.len / 512 > 0xFFFF) 0 else @intCast(fat.len / 512);
    cat[0] = 1;
    cat[30] = 0x55;
    cat[31] = 0xAA;
    var sum: u16 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 2) sum +%= @as(u16, cat[i]) | (@as(u16, cat[i + 1]) << 8);
    le16(cat, 28, 0 -% sum);
    // Initial/default entry: bootable, no emulation, the same image (so the
    // catalog always has a bootable default, like xorriso's).
    cat[32] = 0x88;
    le16(cat, 38, efi_count);
    le32(cat, 40, efi_lba);
    cat[64] = 0x91; // final section header
    cat[65] = 0xEF; // platform: EFI
    le16(cat, 66, 1); // one section entry
    cat[96] = 0x88; // bootable, no emulation
    le16(cat, 102, efi_count);
    le32(cat, 104, efi_lba);

    // Root directory: ".", ".." and nothing else.
    const root = sector(iso, ROOT_LBA);
    _ = putDirRecord(root, 0, ROOT_LBA, ISO_SECTOR, &.{0}, true);
    _ = putDirRecord(root, 34, ROOT_LBA, ISO_SECTOR, &.{1}, true);

    @memcpy(iso[first_data * ISO_SECTOR ..][0..fat.len], fat);
    return iso;
}

pub fn main(init: std.process.Init) !void {
    const a: Allocator = init.arena.allocator();
    const io: Io = init.io;
    const args = try init.minimal.args.toSlice(a);

    // `mkiso --fat <loader> <kernel> <loader.conf> <out.img>`: write only the
    // FAT boot image (the installer copies this onto an EFI system partition).
    if (args.len == 6 and std.mem.eql(u8, args[1], "--fat")) {
        const loader = try Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
        const kernel = try Io.Dir.cwd().readFileAlloc(io, args[3], a, .unlimited);
        const conf = try Io.Dir.cwd().readFileAlloc(io, args[4], a, .unlimited);
        const fat = try buildFat(a, loader, kernel, conf);
        var out = try Io.Dir.cwd().createFile(io, args[5], .{});
        defer out.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var w = out.writer(io, &buf);
        try w.interface.writeAll(fat);
        try w.interface.flush();
        return;
    }

    if (args.len != 5) {
        std.process.fatal("usage: mkiso <kernel> <loader.efi> <loader.conf> <out.iso>", .{});
    }
    const cwd = Io.Dir.cwd();
    const kernel = try cwd.readFileAlloc(io, args[1], a, .unlimited);
    const loader = try cwd.readFileAlloc(io, args[2], a, .unlimited);
    const conf = try cwd.readFileAlloc(io, args[3], a, .unlimited);

    const fat = try buildFat(a, loader, kernel, conf);
    const iso = try buildIso(a, fat);

    var out = try cwd.createFile(io, args[4], .{});
    defer out.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = out.writer(io, &buf);
    try w.interface.writeAll(iso);
    try w.interface.flush();
}
