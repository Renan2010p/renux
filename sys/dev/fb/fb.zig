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
const sysinit: type = @import("../../sys/sysinit.zig");
const prf: type = @import("../../kern/subr_prf.zig");
const rasops: type = @import("../rasops/rasops.zig");

/// Major number of /dev/fb0.
pub const FB_MAJOR: usize = 4;

/// FreeBSD's FBTYPE_EFIFB (sys/sys/fbio.h): the framebuffer came from the
/// firmware's graphical output protocol (Limine hands us one the same way).
const FBTYPE_EFIFB: i32 = 31;

// ioctl numbers, encoded as the BSD _IOR/_IOW macros do (direction in the top
// two bits, size in bits 16..29, 'F' in bits 8..15, number in bits 0..7).
const FBIOGTYPE: u64 = 0x80184600; // _IOR('F', 0, struct fbtype)
const FBIOPUTCMAP: u64 = 0x40204603; // _IOW('F', 3, struct fbcmap)
const FBIOGETCMAP: u64 = 0x40204604; // _IOW('F', 4, struct fbcmap)
const FBIO_GETWINORG: u64 = 0x80046b00; // _IOR('F', 107, u_int)
const FBIO_SETWINORG: u64 = 0x40046c00; // _IOW('F', 108, u_int)
const FBIO_GETLINEWIDTH: u64 = 0x80046f00; // _IOR('F', 111, u_int)
const FBIO_BLANK: u64 = 0x40047300; // _IOW('F', 115, int)
const FBIO_GETRGBOFFS: u64 = 0x800c7400; // _IOR('F', 116, struct fb_rgboffs)

/// struct fbtype (sys/sys/fbio.h).
const FbType: type = extern struct {
    fb_type: i32,
    fb_height: i32,
    fb_width: i32,
    fb_depth: i32,
    fb_cmsize: i32,
    fb_size: i32,
};

/// struct fb_rgboffs (sys/sys/fbio.h).
const FbRgbOffs: type = extern struct {
    red: i32,
    green: i32,
    blue: i32,
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
        FBIOGTYPE => {
            const t: FbType = .{
                .fb_type = FBTYPE_EFIFB,
                .fb_height = @intCast(raster.height),
                .fb_width = @intCast(raster.width),
                .fb_depth = @intCast(raster.depth),
                .fb_cmsize = 0,
                .fb_size = @intCast(size_bytes),
            };
            copyOut(arg, @as([*]const u8, @ptrCast(&t))[0..@sizeOf(FbType)]);
            return 0;
        },
        FBIO_GETLINEWIDTH => {
            putU32(arg, raster.stride);
            return 0;
        },
        FBIO_GETRGBOFFS => {
            const o: FbRgbOffs = .{
                .red = @intCast(raster.red_mask_shift),
                .green = @intCast(raster.green_mask_shift),
                .blue = @intCast(raster.blue_mask_shift),
            };
            copyOut(arg, @as([*]const u8, @ptrCast(&o))[0..@sizeOf(FbRgbOffs)]);
            return 0;
        },
        FBIO_GETWINORG => {
            putU32(arg, 0);
            return 0;
        },
        FBIO_SETWINORG, FBIO_BLANK, FBIOPUTCMAP, FBIOGETCMAP => return 0,
        else => return -errno.ENOTTY,
    }
}

/// Return the framebuffer's physical address for `offset`, so mmap(2) can map
/// it into the caller.
fn fbMmap(ctx: ?*anyopaque, offset: u64, prot: u32) ?u64 {
    _ = ctx;
    _ = prot;
    if (!have_raster or offset >= size_bytes) {
        return null;
    }
    return phys_base + offset;
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
    prf.log(prf.LOG_INFO, "fb: framebuffer device registered", .{});
}

comptime {
    sysinit.SYSINIT("sysinit_fb", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_SECOND, fbInit, null);
}
