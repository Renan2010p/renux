// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// VirtIO block device.
//
// The Zig counterpart of FreeBSD's sys/dev/virtio/block/virtio_blk.c: it
// reads the disk's geometry from the device configuration, sets up the one
// request queue and offers the disk to the system as vtbd<unit>. A request
// is the usual three-part chain (header, data, status byte); data goes
// through a physically contiguous bounce buffer, MAXPHYS at a time, and the
// driver waits for each request to complete.

const arch: type = @import("../../../arch/arch.zig");
const errno: type = @import("../../../sys/errno.zig");
const param: type = @import("../../../sys/param.zig");
const vm_page: type = @import("../../../vm/vm_page.zig");
const prf: type = @import("../../../kern/subr_prf.zig");
const subr_bus: type = @import("../../../kern/subr_bus.zig");
const geom_disk: type = @import("../../../geom/geom_disk.zig");
const virtio: type = @import("../virtio.zig");
const virtqueue: type = @import("../virtqueue.zig");
const vtpci: type = @import("../pci/virtio_pci_legacy.zig");

/// Feature bits (virtio_blk.h).
const VIRTIO_BLK_F_RO: u32 = 1 << 5;
const VIRTIO_BLK_F_BLK_SIZE: u32 = 1 << 6;
const VIRTIO_BLK_F_FLUSH: u32 = 1 << 9;

/// Configuration offsets.
const VTBLK_CONFIG_CAPACITY: u64 = 0;
const VTBLK_CONFIG_BLK_SIZE: u64 = 20;

/// Request types and status values.
const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;
const VIRTIO_BLK_T_FLUSH: u32 = 4;
const VIRTIO_BLK_S_OK: u8 = 0;

/// Capacity is always counted in 512-byte sectors.
const VIRTIO_BLK_SECTOR: u64 = 512;

/// Largest transfer per request (FreeBSD's MAXPHYS was 128 KiB; 64 is plenty).
const MAXPHYS: u64 = 64 * 1024;

/// struct virtio_blk_outhdr.
const OutHdr: type = extern struct {
    type: u32,
    ioprio: u32,
    sector: u64,
};

const Softc: type = struct {
    dev: *vtpci.Vtpci,
    vq: virtqueue.Virtqueue,
    features: u32,
    disk: geom_disk.Disk,
    /// One page holding the request header and the status byte.
    hdr_pa: u64,
    hdr: *volatile OutHdr,
    status: *volatile u8,
    /// MAXPHYS of contiguous memory for the data.
    buf_pa: u64,
    buf: [*]u8,
};

const MAXUNITS: usize = 4;
var softc: [MAXUNITS]Softc = undefined;
var nunits: u32 = 0;

/// Run one request of `len` bytes at 512-byte sector `sector`; the data is
/// in the bounce buffer. Returns 0 or an errno.
fn request(sc: *Softc, kind: u32, sector: u64, len: u32) i32 {
    sc.hdr.* = .{ .type = kind, .ioprio = 0, .sector = sector };
    sc.status.* = 0xff;
    var segs: [3]virtqueue.Segment = undefined;
    var n: usize = 0;
    segs[n] = .{ .paddr = sc.hdr_pa, .len = @sizeOf(OutHdr), .device_writes = false };
    n += 1;
    if (len > 0) {
        segs[n] = .{ .paddr = sc.buf_pa, .len = len, .device_writes = kind == VIRTIO_BLK_T_IN };
        n += 1;
    }
    segs[n] = .{ .paddr = sc.hdr_pa + @sizeOf(OutHdr), .len = 1, .device_writes = true };
    n += 1;
    if (!virtqueue.enqueueWait(&sc.vq, segs[0..n])) return errno.EIO;
    sc.dev.ackInterrupt();
    return if (sc.status.* == VIRTIO_BLK_S_OK) 0 else errno.EIO;
}

fn strategy(dp: *geom_disk.Disk, write: bool, offset: u64, data: []u8) i32 {
    const sc: *Softc = @ptrCast(@alignCast(dp.d_drv1.?));
    if (offset % VIRTIO_BLK_SECTOR != 0 or data.len % VIRTIO_BLK_SECTOR != 0) return errno.EINVAL;
    if (offset + data.len > dp.d_mediasize) return errno.EIO;
    if (write and dp.d_readonly) return errno.EROFS;
    var done: usize = 0;
    while (done < data.len) {
        const chunk: usize = @intCast(@min(MAXPHYS, data.len - done));
        const sector: u64 = (offset + done) / VIRTIO_BLK_SECTOR;
        if (write) {
            @memcpy(sc.buf[0..chunk], data[done .. done + chunk]);
            const e: i32 = request(sc, VIRTIO_BLK_T_OUT, sector, @intCast(chunk));
            if (e != 0) return e;
        } else {
            const e: i32 = request(sc, VIRTIO_BLK_T_IN, sector, @intCast(chunk));
            if (e != 0) return e;
            @memcpy(data[done .. done + chunk], sc.buf[0..chunk]);
        }
        done += chunk;
    }
    return 0;
}

fn flush(dp: *geom_disk.Disk) i32 {
    const sc: *Softc = @ptrCast(@alignCast(dp.d_drv1.?));
    if ((sc.features & VIRTIO_BLK_F_FLUSH) == 0) return 0;
    return request(sc, VIRTIO_BLK_T_FLUSH, 0, 0);
}

/// Attach the block device behind `dev` (called by the PCI transport).
pub fn attach(dev: *vtpci.Vtpci) bool {
    if (nunits >= MAXUNITS) return false;
    const unit: u32 = nunits;
    const sc: *Softc = &softc[unit];
    const self: subr_bus.Device = .{ .name = "vtblk", .unit = unit, .desc = "VirtIO Block Adapter", .parent = dev.parentName() };
    subr_bus.announce(&self, "", .{});

    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    sc.dev = dev;
    sc.features = dev.negotiateFeatures(VIRTIO_BLK_F_RO | VIRTIO_BLK_F_BLK_SIZE | VIRTIO_BLK_F_FLUSH);

    var cap_bytes: [8]u8 = undefined;
    dev.readDevConfig(VTBLK_CONFIG_CAPACITY, &cap_bytes);
    const capacity: u64 = @bitCast(cap_bytes);
    var sectorsize: u32 = VIRTIO_BLK_SECTOR;
    if ((sc.features & VIRTIO_BLK_F_BLK_SIZE) != 0) {
        var bs: [4]u8 = undefined;
        dev.readDevConfig(VTBLK_CONFIG_BLK_SIZE, &bs);
        const v: u32 = @bitCast(bs);
        if (v >= 512 and v <= 4096) sectorsize = v;
    }

    if (!dev.allocVirtqueue(&sc.vq, 0)) {
        subr_bus.device_printf(&self, "cannot allocate virtqueue\n", .{});
        return false;
    }
    sc.hdr_pa = vm_page.physalloc() orelse return false;
    sc.hdr = @ptrFromInt(sc.hdr_pa + hhdm);
    sc.status = @ptrFromInt(sc.hdr_pa + hhdm + @sizeOf(OutHdr));
    sc.buf_pa = vm_page.physallocContig(MAXPHYS / param.PAGE_SIZE) orelse return false;
    sc.buf = @ptrFromInt(sc.buf_pa + hhdm);

    dev.setStatus(virtio.VIRTIO_CONFIG_STATUS_DRIVER_OK);

    sc.disk = .{
        .d_name = "vtbd",
        .d_unit = unit,
        .d_sectorsize = sectorsize,
        .d_mediasize = capacity * VIRTIO_BLK_SECTOR,
        .d_readonly = (sc.features & VIRTIO_BLK_F_RO) != 0,
        .d_strategy = strategy,
        .d_flush = flush,
        .d_drv1 = sc,
    };
    geom_disk.disk_create(&sc.disk);
    nunits += 1;

    // "vtblk0: 64MB (131072 512 byte sectors)", as FreeBSD reports a disk.
    subr_bus.device_printf(&self, "%uMB (%u %u byte sectors)\n", .{
        sc.disk.d_mediasize / (1024 * 1024),
        sc.disk.d_mediasize / sectorsize,
        sectorsize,
    });
    return true;
}
