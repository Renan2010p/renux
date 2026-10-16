// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ATA/IDE disks (PIO).
//
// The Zig counterpart of the legacy ATA driver: it looks at the standard IDE
// channels (the fixed I/O ports an ATA controller answers on, primary at
// 0x1F0/0x3F6 and secondary at 0x170/0x376), IDENTIFYs each of the four
// drives and offers the ones that are plain ATA disks to the system as
// /dev/sda, /dev/sdb, ... (Linux names SATA/IDE disks sd*; the ATA CD-ROM on
// the same channels answers IDENTIFY as ATAPI and is left alone).
//
// Transfers are programmed I/O, 512 bytes per sector, LBA28 or LBA48. That is
// all a QEMU `-hda` disk needs, and it works on real hardware whose IDE
// controller exposes the legacy task file. DMA and AHCI (the SATA controller
// modern machines have) are not implemented yet.

const geom_disk: type = @import("../../geom/geom_disk.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const errno: type = @import("../../sys/errno.zig");
const prf: type = @import("../../core/subr_prf.zig");

const SECTOR: u64 = 512;

/// Primary and secondary channel I/O base and control (alternate status) ports.
const PRIMARY_IO: u16 = 0x1F0;
const PRIMARY_CTRL: u16 = 0x3F6;
const SECONDARY_IO: u16 = 0x170;
const SECONDARY_CTRL: u16 = 0x376;

// Task-file register offsets from the I/O base.
const R_DATA: u16 = 0;
const R_FEATURES: u16 = 1;
const R_COUNT: u16 = 2;
const R_LBA0: u16 = 3;
const R_LBA1: u16 = 4;
const R_LBA2: u16 = 5;
const R_DRIVE: u16 = 6;
const R_STATUS: u16 = 7;

const ST_BSY: u8 = 0x80;
const ST_DRDY: u8 = 0x40;
const ST_DF: u8 = 0x20;
const ST_DRQ: u8 = 0x08;
const ST_ERR: u8 = 0x01;

// Commands.
const CMD_READ28: u8 = 0x20;
const CMD_WRITE28: u8 = 0x30;
const CMD_READ48: u8 = 0x24;
const CMD_WRITE48: u8 = 0x34;
const CMD_IDENTIFY: u8 = 0xEC;
const CMD_FLUSH: u8 = 0xE7;

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}
fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}
fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

/// One attached drive: the channel it lives on and its geometry.
const Drive: type = struct {
    io: u16,
    ctrl: u16,
    slave: u1,
    lba48: bool,
};

var drives: [4]Drive = undefined;
var ndrives: usize = 0;
var disks: [4]geom_disk.Disk = undefined;

/// 400 ns by reading the alternate status port four times.
fn ioDelay(ctrl: u16) void {
    _ = inb(ctrl);
    _ = inb(ctrl);
    _ = inb(ctrl);
    _ = inb(ctrl);
}

/// Wait for the drive to leave BSY. Returns false on error or timeout.
fn waitReady(io: u16) bool {
    var i: usize = 0;
    while (i < 4_000_000) : (i += 1) {
        const st: u8 = inb(io + R_STATUS);
        if ((st & ST_BSY) == 0) return (st & ST_ERR) == 0 and (st & ST_DF) == 0;
    }
    return false;
}

/// Wait until the drive is ready to move data (DRQ). Returns false on error.
fn waitDrq(io: u16) bool {
    var i: usize = 0;
    while (i < 4_000_000) : (i += 1) {
        const st: u8 = inb(io + R_STATUS);
        if ((st & ST_BSY) == 0) {
            if ((st & ST_ERR) != 0 or (st & ST_DF) != 0) return false;
            if ((st & ST_DRQ) != 0) return true;
        }
    }
    return false;
}

/// IDENTIFY DEVICE; returns the 256-word identification, or null when the
/// drive is absent or is not a plain ATA disk (ATAPI, SATA without the bridge,
/// ...). IDENTIFY is PIO data-in, so it also tells us the drive answers.
fn identify(io: u16, ctrl: u16, slave: u1) ?[256]u16 {
    outb(io + R_DRIVE, 0xA0 | (@as(u8, slave) << 4));
    ioDelay(ctrl);
    outb(io + R_COUNT, 0);
    outb(io + R_LBA0, 0);
    outb(io + R_LBA1, 0);
    outb(io + R_LBA2, 0);
    outb(io + R_STATUS, CMD_IDENTIFY);
    ioDelay(ctrl);

    if (inb(io + R_STATUS) == 0) return null; // no drive
    if (!waitReady(io)) return null;
    // An ATAPI device leaves a signature in the LBA mid/high registers.
    if (inb(io + R_LBA1) != 0 or inb(io + R_LBA2) != 0) return null;
    if (!waitDrq(io)) return null;

    var id: [256]u16 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) id[i] = inw(io);
    return id;
}

/// Start one PIO command for `count` sectors at `lba`.
fn issue(d: *const Drive, write: bool, lba: u64, count: u32) void {
    const io: u16 = d.io;
    const sel: u8 = @as(u8, d.slave) << 4;
    if (d.lba48) {
        outb(io + R_DRIVE, 0x40 | sel);
        outb(io + R_FEATURES, 0);
        outb(io + R_COUNT, @truncate(count >> 8));
        outb(io + R_LBA0, @truncate(lba >> 24));
        outb(io + R_LBA1, @truncate(lba >> 32));
        outb(io + R_LBA2, @truncate(lba >> 40));
        outb(io + R_COUNT, @truncate(count));
        outb(io + R_LBA0, @truncate(lba));
        outb(io + R_LBA1, @truncate(lba >> 8));
        outb(io + R_LBA2, @truncate(lba >> 16));
        outb(io + R_STATUS, if (write) CMD_WRITE48 else CMD_READ48);
    } else {
        outb(io + R_DRIVE, 0xE0 | sel | @as(u8, @truncate((lba >> 24) & 0x0F)));
        outb(io + R_FEATURES, 0);
        outb(io + R_COUNT, @truncate(count));
        outb(io + R_LBA0, @truncate(lba));
        outb(io + R_LBA1, @truncate(lba >> 8));
        outb(io + R_LBA2, @truncate(lba >> 16));
        outb(io + R_STATUS, if (write) CMD_WRITE28 else CMD_READ28);
    }
}

/// Read or write `count` sectors from `lba` through PIO.
fn pio(d: *const Drive, write: bool, lba: u64, count: u32, buf: []u8) i32 {
    if (!waitReady(d.io)) return errno.EIO;
    issue(d, write, lba, count);
    ioDelay(d.ctrl);
    var s: u32 = 0;
    while (s < count) : (s += 1) {
        if (!waitDrq(d.io)) return errno.EIO;
        const base: usize = @as(usize, s) * 512;
        var w: usize = 0;
        if (write) {
            while (w < 256) : (w += 1) {
                const lo: u16 = buf[base + w * 2];
                const hi: u16 = buf[base + w * 2 + 1];
                outw(d.io + R_DATA, lo | (hi << 8));
            }
        } else {
            while (w < 256) : (w += 1) {
                const v: u16 = inw(d.io + R_DATA);
                buf[base + w * 2] = @truncate(v);
                buf[base + w * 2 + 1] = @truncate(v >> 8);
            }
        }
    }
    // Discard the trailing status so the drive latches the next command.
    _ = inb(d.io + R_STATUS);
    return 0;
}

fn strategy(dp: *geom_disk.Disk, write: bool, offset: u64, data: []u8) i32 {
    const d: *Drive = @ptrCast(@alignCast(dp.d_drv1.?));
    if (offset % SECTOR != 0 or data.len % SECTOR != 0) return errno.EINVAL;
    if (offset + data.len > dp.d_mediasize) return errno.EIO;
    var lba: u64 = offset / SECTOR;
    var done: usize = 0;
    while (done < data.len) {
        const max_sectors: usize = if (d.lba48) 65536 else 255;
        const count: usize = @min((data.len - done) / @as(usize, SECTOR), max_sectors);
        const e: i32 = pio(d, write, lba, @intCast(count), data[done .. done + count * 512]);
        if (e != 0) return e;
        lba += count;
        done += count * 512;
    }
    return 0;
}

fn flush(dp: *geom_disk.Disk) i32 {
    const d: *Drive = @ptrCast(@alignCast(dp.d_drv1.?));
    if (!waitReady(d.io)) return errno.EIO;
    outb(d.io + R_STATUS, CMD_FLUSH);
    return if (waitReady(d.io)) 0 else errno.EIO;
}

fn probe(io: u16, ctrl: u16, slave: u1) void {
    const id: [256]u16 = identify(io, ctrl, slave) orelse return;
    // General configuration: bit 15 set means ATAPI, which we do not drive.
    if ((id[0] & 0x8000) != 0) return;

    const lba28: u64 = @as(u64, id[60]) | (@as(u64, id[61]) << 16);
    const lba48_sup: bool = (id[83] & 0x0400) != 0;
    var lba48: u64 = 0;
    if (lba48_sup) {
        lba48 = @as(u64, id[100]) | (@as(u64, id[101]) << 16) |
            (@as(u64, id[102]) << 32) | (@as(u64, id[103]) << 48);
    }
    const sectors: u64 = if (lba48 != 0) lba48 else lba28;
    if (sectors == 0) return;
    const use48: bool = lba48 != 0;

    const idx: usize = ndrives;
    drives[idx] = .{ .io = io, .ctrl = ctrl, .slave = slave, .lba48 = use48 };
    disks[idx] = .{
        .d_name = "sd",
        .d_unit = @intCast(idx),
        .d_sectorsize = @intCast(SECTOR),
        .d_mediasize = sectors * SECTOR,
        .d_strategy = strategy,
        .d_flush = flush,
        .d_drv1 = &drives[idx],
    };
    geom_disk.disk_create(&disks[idx]);
    ndrives += 1;

    var nb: [16]u8 = undefined;
    const name: []const u8 = geom_disk.devName(&disks[idx], &nb);
    prf.printf("%s: %uMB (%u %u byte sectors)%s\n", .{
        name,
        disks[idx].d_mediasize / (1024 * 1024),
        sectors,
        SECTOR,
        if (use48) " LBA48" else "",
    });
}

fn attach(_: ?*const anyopaque) callconv(.c) void {
    probe(PRIMARY_IO, PRIMARY_CTRL, 0);
    probe(PRIMARY_IO, PRIMARY_CTRL, 1);
    probe(SECONDARY_IO, SECONDARY_CTRL, 0);
    probe(SECONDARY_IO, SECONDARY_CTRL, 1);
}

comptime {
    sysinit.SYSINIT("sysinit_ata", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_THIRD, attach, null);
}
