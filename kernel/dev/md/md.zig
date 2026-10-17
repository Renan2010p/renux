// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Memory disks: the boot images as read-only disks.
//
// FreeBSD's md(4) device backed by kernel memory. Here it exposes the images
// the kernel carries (the root image, kernel/fs/rootimage.zig) as /dev/md0 --
// and, when the build embedded an installer payload, the ESP image as
// /dev/md1 and the compressed installed root (kernel/fs/sysimage.zig) as
// /dev/md2.
// The installer copies them onto a target disk; nothing on the live system
// writes to them.
//
// The disks are named md0, md1, md2 (a number, not a letter): they are read-only
// images, not drives.

const geom_disk: type = @import("../../geom/geom_disk.zig");
const rootimage: type = @import("../../fs/rootimage.zig");
const espimage: type = @import("../../fs/espimage.zig");
const sysimage: type = @import("../../fs/sysimage.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const errno: type = @import("../../sys/errno.zig");
const prf: type = @import("../../core/subr_prf.zig");

const Md: type = struct { data: []const u8 };

var md0: Md = undefined;
var md1: Md = undefined;
var md2: Md = undefined;
var disks: [3]geom_disk.Disk = undefined;

fn strategy(dp: *geom_disk.Disk, write: bool, offset: u64, buf: []u8) i32 {
    const m: *Md = @ptrCast(@alignCast(dp.d_drv1.?));
    if (write) return errno.EROFS;
    if (offset + buf.len > m.data.len) return errno.EIO;
    @memcpy(buf, m.data[@intCast(offset)..@intCast(offset + buf.len)]);
    return 0;
}

fn add(unit: u32, m: *Md) void {
    if (m.data.len == 0) return;
    const d: *geom_disk.Disk = &disks[unit];
    d.* = .{
        .d_name = "md",
        .d_unit = unit,
        .d_unit_letter = false,
        .d_sectorsize = 512,
        .d_mediasize = m.data.len,
        .d_readonly = true,
        .d_strategy = strategy,
        .d_drv1 = m,
    };
    geom_disk.disk_create(d);
    var nb: [16]u8 = undefined;
    prf.printf("%s: %uMB embedded image\n", .{ geom_disk.devName(d, &nb), m.data.len / (1024 * 1024) });
}

fn attach(_: ?*const anyopaque) callconv(.c) void {
    md0 = .{ .data = rootimage.bytes };
    add(0, &md0);
    md1 = .{ .data = espimage.bytes };
    add(1, &md1);
    md2 = .{ .data = sysimage.bytes };
    add(2, &md2);
}

comptime {
    sysinit.SYSINIT("sysinit_md", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_THIRD, attach, null);
}
