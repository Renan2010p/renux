// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Framebuffer device (/dev/fb0).
//
// Exposes the boot framebuffer to userland so a graphical server can draw on
// it. The ioctls and structures match FreeBSD's sys/sys/fbio.h, which is what
// Xorg's scfb(4) driver (x11-drivers/xf86-video-scfb) uses: FBIOGTYPE for the
// geometry, FBIO_GETLINEWIDTH for the stride and FBIO_GETRGBOFFS for the
// channel shifts; mmap(2) maps the framebuffer's physical memory.

const conf: type = @import("../../sys/conf.zig");
const errno: type = @import("../../sys/errno.zig");
const fbio: type = @import("../../sys/fbio.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const prf: type = @import("../../kern/subr_prf.zig");
const subr_bus: type = @import("../../kern/subr_bus.zig");
const rasops: type = @import("../rasops/rasops.zig");
const param: type = @import("../../sys/param.zig");

/// Major number of /dev/fb0.
pub const FB_MAJOR: usize = 4;

const fb_dev: subr_bus.Device = .{
    .name = "fb",
    .desc = "boot framebuffer",
    .parent = "nexus0",
};

/// The framebuffer, captured at console attach time. `attach` runs before the
/// driver's SYSINIT, so the state lives here rather than in the open context.
var raster: rasops.Raster = undefined;
var have_raster: bool = false;
var phys_base: u64 = 0;
var size_bytes: u64 = 0;

/// Record the boot framebuffer (machine-independent raster plus the physical
/// base and total size). Called from consinit, which has both.
pub fn attach(r: rasops.Raster, phys: u64, size: u64) void {
    raster = r;
    have_raster = true;
    phys_base = phys;
    size_bytes = size;
}

/// Copy `src` to user address `addr` (a tiny copyout; ioctl arguments are
/// already validated by the generic layer).
fn copyOut(addr: u64, src: []const u8) void {
    const dst: [*]u8 = @ptrFromInt(addr);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        dst[i] = src[i];
    }
}

fn putU32(addr: u64, v: u32) void {
    const dst: *align(1) u32 = @ptrFromInt(addr);
    dst.* = v;
}

fn fbOpen(dev: u64, flags: i32) ?*anyopaque {
    _ = dev;
    _ = flags;
    return null;
}

fn fbClose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

fn fbRead(ctx: ?*anyopaque, buf: []u8) isize {
    _ = ctx;
    _ = buf;
    return -errno.EINVAL;
}

fn fbWrite(ctx: ?*anyopaque, buf: []const u8) isize {
    _ = ctx;
    _ = buf;
    return -errno.EINVAL;
}

fn fbIoctl(ctx: ?*anyopaque, cmd: u64, arg: u64) i32 {
    _ = ctx;
    if (!have_raster) {
        return -errno.ENXIO;
    }
    switch (cmd) {
        fbio.FBIOGTYPE => {
            const t: fbio.FbType = .{
                .fb_type = fbio.FBTYPE_EFIFB,
                .fb_height = @intCast(raster.height),
                .fb_width = @intCast(raster.width),
                .fb_depth = @intCast(raster.depth),
                .fb_cmsize = 0,
                .fb_size = @intCast(size_bytes),
            };
            copyOut(arg, @as([*]const u8, @ptrCast(&t))[0..@sizeOf(fbio.FbType)]);
            return 0;
        },
        fbio.FBIO_GETLINEWIDTH => {
            putU32(arg, raster.stride);
            return 0;
        },
        fbio.FBIO_GETRGBOFFS => {
            const o: fbio.FbRgbOffs = .{
                .red = @intCast(raster.red_mask_shift),
                .green = @intCast(raster.green_mask_shift),
                .blue = @intCast(raster.blue_mask_shift),
            };
            copyOut(arg, @as([*]const u8, @ptrCast(&o))[0..@sizeOf(fbio.FbRgbOffs)]);
            return 0;
        },
        fbio.FBIO_GETWINORG => {
            // A linear framebuffer is one window at offset 0.
            putU32(arg, 0);
            return 0;
        },
        fbio.FBIO_GETDISPSTART => {
            const d: fbio.DisplayStart = .{ .x = 0, .y = 0 };
            copyOut(arg, @as([*]const u8, @ptrCast(&d))[0..@sizeOf(fbio.DisplayStart)]);
            return 0;
        },
        fbio.FBIO_SETWINORG, fbio.FBIO_SETDISPSTART => {
            // Only the origin the hardware already uses is accepted.
            const v: *align(1) const u32 = @ptrFromInt(arg);
            return if (v.* == 0) 0 else -errno.EINVAL;
        },
        fbio.FBIO_BLANK => {
            // There is no display power management; accept "on" and refuse
            // the blanking levels honestly.
            const v: *align(1) const i32 = @ptrFromInt(arg);
            return if (v.* == fbio.V_DISPLAY_ON) 0 else -errno.ENODEV;
        },
        // A direct-colour framebuffer has no colour map.
        fbio.FBIOGETCMAP, fbio.FBIOPUTCMAP => return -errno.ENODEV,
        else => return -errno.ENOTTY,
    }
}

/// Return the framebuffer's physical address for `offset`, so mmap(2) can map
/// it into the caller.
fn fbMmap(ctx: ?*anyopaque, offset: u64, prot: u32) ?u64 {
    _ = ctx;
    _ = prot;
    // Whole pages only: the last page may extend past the visible buffer but
    // never past the page that holds its last byte.
    const span: u64 = param.alignUp(size_bytes + (phys_base % param.PAGE_SIZE), param.PAGE_SIZE);
    if (!have_raster or offset >= span) {
        return null;
    }
    return (phys_base & ~@as(u64, param.PAGE_SIZE - 1)) + offset;
}

const fb_cdevsw: conf.Cdevsw = .{
    .name = "fb",
    .open = fbOpen,
    .read = fbRead,
    .write = fbWrite,
    .ioctl = fbIoctl,
    .mmap = fbMmap,
    .close = fbClose,
};

fn fbInit(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(FB_MAJOR, &fb_cdevsw);
    if (have_raster and prf.bootverbose) {
        subr_bus.announce(&fb_dev, " %ux%u %u bpp, %u bytes at %x", .{
            raster.width, raster.height, raster.depth, size_bytes, phys_base,
        });
        if (!rasops.supported(&raster)) {
            subr_bus.device_printf(&fb_dev, "pixel format not supported by the text console\n", .{});
        }
    }
}

comptime {
    sysinit.SYSINIT("sysinit_fb", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_FIFTH, fbInit, null);
}
