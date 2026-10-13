// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Framebuffer ioctls.
//
// The Zig counterpart of FreeBSD's sys/sys/fbio.h, reduced to what a linear
// framebuffer answers. These are the requests Xorg's scfb(4) driver and other
// FreeBSD programs issue on /dev/fb0, so the numbers and layouts must match
// FreeBSD/amd64 exactly.

const ioccom: type = @import("ioccom.zig");

/// FBTYPE_EFIFB: a linear framebuffer handed over by the firmware or loader.
pub const FBTYPE_EFIFB: i32 = 31;

/// struct fbtype.
pub const FbType: type = extern struct {
    fb_type: i32, // FBTYPE_*
    fb_height: i32, // in pixels
    fb_width: i32, // in pixels
    fb_depth: i32, // bits per pixel
    fb_cmsize: i32, // colour map entries
    fb_size: i32, // total size in bytes
};

/// struct fbcmap.
pub const FbCmap: type = extern struct {
    index: i32,
    count: i32,
    red: ?[*]u8,
    green: ?[*]u8,
    blue: ?[*]u8,
};

/// struct fb_rgboffs: the bit offset of each colour channel in a pixel.
pub const FbRgbOffs: type = extern struct {
    red: i32,
    green: i32,
    blue: i32,
};

/// video_display_start_t.
pub const DisplayStart: type = extern struct {
    x: i32,
    y: i32,
};

pub const FBIOGTYPE: u64 = ioccom.ior('F', 0, FbType);
pub const FBIOPUTCMAP: u64 = ioccom.iow('F', 3, FbCmap);
pub const FBIOGETCMAP: u64 = ioccom.iow('F', 4, FbCmap);
pub const FBIO_GETWINORG: u64 = ioccom.ior('F', 107, c_uint);
pub const FBIO_SETWINORG: u64 = ioccom.iow('F', 108, c_uint);
pub const FBIO_GETDISPSTART: u64 = ioccom.ior('F', 109, DisplayStart);
pub const FBIO_SETDISPSTART: u64 = ioccom.iow('F', 110, DisplayStart);
pub const FBIO_GETLINEWIDTH: u64 = ioccom.ior('F', 111, c_uint);
pub const FBIO_BLANK: u64 = ioccom.iow('F', 115, c_int);
pub const FBIO_GETRGBOFFS: u64 = ioccom.ior('F', 116, FbRgbOffs);

/// FBIO_BLANK arguments (V_DISPLAY_* in sys/sys/fbio.h).
pub const V_DISPLAY_ON: i32 = 0;
pub const V_DISPLAY_BLANK: i32 = 1;
