// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Partitions (GEOM slices).
//
// The Zig counterpart of FreeBSD's sys/geom/part, reduced to what an
// installer needs: at boot each whole disk is tasted, and its MBR or GPT
// partitions are offered to the rest of the kernel as the disks of a "slice"
// layer -- a Disk that forwards every request to its parent with the
// partition's byte offset added, and whose media size is the partition's.
//
// Names follow Linux: the whole disk is /dev/vda (a virtio disk), /dev/sda
// (a SATA/SCSI one), and its partitions are /dev/vda1, /dev/vda2, ...
//
// There is no partition editing yet: the installer writes the table itself
// (tools/... on the host, or a future on-target editor) and the kernel only
// reads it.

const std: type = @import("std");
const geom_disk: type = @import("geom_disk.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const errno: type = @import("../sys/errno.zig");
const prf: type = @import("../core/subr_prf.zig");

const MAXSLICES: usize = 16;

/// A partition of a whole disk: a Disk that offsets every request.
const Slice: type = struct {
    disk: geom_disk.Disk,
    parent: *geom_disk.Disk,
    /// Byte offset of the partition on the parent.
    base: u64,
    /// The full device name ("vda1"), which disk.d_name points into.
    name: [16]u8 = undefined,
};

var slices: [MAXSLICES]Slice = undefined;
var nslices: usize = 0;

fn sliceStrategy(dp: *geom_disk.Disk, write: bool, offset: u64, data: []u8) i32 {
    const s: *Slice = @fieldParentPtr("disk", dp);
    if (offset + data.len > dp.d_mediasize) return errno.EIO;
    return s.parent.d_strategy(s.parent, write, s.base + offset, data);
}

fn sliceFlush(dp: *geom_disk.Disk) i32 {
    const s: *Slice = @fieldParentPtr("disk", dp);
    if (s.parent.d_flush) |f| return f(s.parent);
    return 0;
}

fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16 | @as(u32, b[3]) << 24;
}

fn le64(b: []const u8) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, b[i]) << @intCast(i * 8);
    return v;
}

/// Offer partition `num` of `parent` as a slice disk.
fn addSlice(parent: *geom_disk.Disk, num: u32, base: u64, size: u64) void {
    if (nslices >= MAXSLICES or size == 0) return;
    const s: *Slice = &slices[nslices];
    var nb: [16]u8 = undefined;
    const pname: []const u8 = geom_disk.devName(parent, &nb);
    const n: usize = @min(pname.len, s.name.len);
    @memcpy(s.name[0..n], pname[0..n]);
    s.parent = parent;
    s.base = base;
    s.disk = .{
        .d_name = s.name[0..n],
        .d_unit = num,
        .d_unit_letter = false,
        .d_sectorsize = parent.d_sectorsize,
        .d_mediasize = size,
        .d_readonly = parent.d_readonly,
        .d_strategy = sliceStrategy,
        .d_flush = sliceFlush,
        .d_drv1 = s,
    };
    geom_disk.disk_create(&s.disk);
    nslices += 1;

    var full: [16]u8 = undefined;
    const fname: []const u8 = geom_disk.devName(&s.disk, &full);
    prf.printf("%s: partition %u, %uMB at offset %u\n", .{
        fname, num, size / (1024 * 1024), base,
    });
}

/// Scratch for a disk's GPT entry table (128 entries x 128 bytes is the
/// usual 16 KiB; up to 64 KiB is read). Tasting is sequential, so one buffer
/// is enough.
var gpt_table: [64 * 1024 + 512]u8 = undefined;

/// Read the MBR at sector 0; returns true when it holds a table.
fn readMbr(dp: *geom_disk.Disk, sec: *[512]u8) bool {
    if (dp.d_strategy(dp, false, 0, sec) != 0) return false;
    return sec[510] == 0x55 and sec[511] == 0xAA;
}

fn tasteMbr(dp: *geom_disk.Disk, sec: *const [512]u8) void {
    const s: []const u8 = sec;
    var e: usize = 446;
    var p: u32 = 1;
    while (p <= 4) : (p += 1) {
        const typ: u8 = s[e + 4];
        const first: u64 = le32(s[e + 8 .. e + 12]);
        const count: u64 = le32(s[e + 12 .. e + 16]);
        if (typ != 0 and count != 0) {
            addSlice(dp, p, first * dp.d_sectorsize, count * dp.d_sectorsize);
        }
        e += 16;
    }
}

fn tasteGpt(dp: *geom_disk.Disk) void {
    var hdr: [512]u8 = undefined;
    if (dp.d_strategy(dp, false, dp.d_sectorsize, &hdr) != 0) return;
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return;

    const entry_size: u64 = le32(hdr[84..88]);
    const num_entries: u64 = le32(hdr[80..84]);
    const entries_lba: u64 = le64(hdr[72..80]);
    if (entry_size < 128 or entry_size % 8 != 0 or num_entries == 0) return;
    const table: u64 = entry_size * num_entries;
    if (table > 64 * 1024) return; // more than the kernel cares to read

    // Round the read up to a whole sector, as the disk strategy requires.
    const read_len: usize = @intCast((table + dp.d_sectorsize - 1) / dp.d_sectorsize * dp.d_sectorsize);
    if (read_len > gpt_table.len) return;
    const buf: []u8 = gpt_table[0..read_len];
    if (dp.d_strategy(dp, false, entries_lba * dp.d_sectorsize, buf) != 0) {
        prf.log(prf.LOG_ERR, "geom_part: cannot read the GPT entry table", .{});
        return;
    }

    var i: u64 = 0;
    while (i < num_entries) : (i += 1) {
        const off: usize = @intCast(i * entry_size);
        const ent = buf[off .. off + @as(usize, @intCast(entry_size))];
        // A free entry has an all-zero type GUID.
        var zero: bool = true;
        for (ent[0..16]) |b| {
            if (b != 0) {
                zero = false;
                break;
            }
        }
        if (i < 3) {
            prf.log(prf.LOG_DEBUG, "geom_part: entry %u zero=%u first=%u last=%u", .{
                i, @intFromBool(zero), le64(ent[32..40]), le64(ent[40..48]),
            });
        }
        if (zero) continue;
        const first: u64 = le64(ent[32..40]);
        const last: u64 = le64(ent[40..48]);
        if (last < first) continue;
        addSlice(dp, @intCast(i + 1), first * dp.d_sectorsize, (last - first + 1) * dp.d_sectorsize);
    }
}

fn taste(dp: *geom_disk.Disk) void {
    var sec: [512]u8 = undefined;
    if (!readMbr(dp, &sec)) return;
    // A GPT disk carries a protective MBR (type 0xEE); the real table is in
    // the GPT header at LBA 1.
    var protective: bool = false;
    var e: usize = 446;
    var p: u32 = 0;
    while (p < 4) : (p += 1) {
        if (sec[e + 4] == 0xEE) protective = true;
        e += 16;
    }
    if (protective) tasteGpt(dp) else tasteMbr(dp, &sec);
}

fn partitionTaste(_: ?*const anyopaque) callconv(.c) void {
    geom_disk.retaste = taste;
    const n: usize = geom_disk.list().len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dp: *geom_disk.Disk = geom_disk.list()[i];
        if (!dp.d_unit_letter) continue; // slices are not re-tasted
        taste(dp);
    }
}

comptime {
    sysinit.SYSINIT("sysinit_geom_part", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_ANY, partitionTaste, null);
}
