// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/fbdraw: paint the framebuffer through /dev/fb0.
//
// A test of the framebuffer device that takes the same path a graphical
// server's scfb(4) driver does:
//
//   1. put the console in graphics mode (KDSETMODE KD_GRAPHICS), so the text
//      console stops drawing over the picture;
//   2. ask /dev/fb0 for the geometry (FBIOGTYPE), the line length
//      (FBIO_GETLINEWIDTH) and the channel layout (FBIO_GETRGBOFFS);
//   3. mmap(2) the framebuffer and paint a gradient with colour bars;
//   4. wait for Enter, then give the screen back (KDSETMODE KD_TEXT), which
//      makes the console repaint its text.

const libc: type = @import("libc");
const syscall: type = libc.syscall;

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

// mmap(2) constants (FreeBSD).
const PROT_READ: u64 = 0x1;
const PROT_WRITE: u64 = 0x2;
const MAP_SHARED: u64 = 0x1;
// open(2) flag.
const O_RDWR: u64 = 0x2;

// ioctl encoding (FreeBSD's sys/ioccom.h).
const IOC_VOID: u64 = 0x20000000;
const IOC_OUT: u64 = 0x40000000;

fn ioc(dir: u64, group: u8, num: u8, len: usize) u64 {
    return dir | (@as(u64, len) << 16) | (@as(u64, group) << 8) | num;
}

/// struct fbtype (sys/fbio.h).
const FbType: type = extern struct {
    fb_type: i32,
    fb_height: i32,
    fb_width: i32,
    fb_depth: i32,
    fb_cmsize: i32,
    fb_size: i32,
};

/// struct fb_rgboffs (sys/fbio.h).
const FbRgbOffs: type = extern struct {
    red: i32,
    green: i32,
    blue: i32,
};

const FBIOGTYPE: u64 = ioc(IOC_OUT, 'F', 0, @sizeOf(FbType));
const FBIO_GETLINEWIDTH: u64 = ioc(IOC_OUT, 'F', 111, @sizeOf(u32));
const FBIO_GETRGBOFFS: u64 = ioc(IOC_OUT, 'F', 116, @sizeOf(FbRgbOffs));
const KDSETMODE: u64 = ioc(IOC_VOID, 'K', 10, @sizeOf(c_int));
const KD_TEXT: u64 = 0;
const KD_GRAPHICS: u64 = 1;

/// Pack an RGB triple for an 8-bit-per-channel layout.
fn rgb(o: FbRgbOffs, r: u32, g: u32, b: u32) u32 {
    return (r << @intCast(o.red)) | (g << @intCast(o.green)) | (b << @intCast(o.blue));
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;

    const fd: i64 = syscall.open("/dev/fb0", O_RDWR, 0);
    if (fd < 0) {
        libc.stdio.puts("fbdraw: cannot open /dev/fb0");
        return 1;
    }
    const ufd: u64 = @intCast(fd);

    var t: FbType = undefined;
    var stride: u32 = 0;
    var offs: FbRgbOffs = .{ .red = 16, .green = 8, .blue = 0 };
    if (syscall.ioctl(ufd, FBIOGTYPE, @intFromPtr(&t)) < 0 or
        syscall.ioctl(ufd, FBIO_GETLINEWIDTH, @intFromPtr(&stride)) < 0)
    {
        libc.stdio.puts("fbdraw: /dev/fb0 does not answer FBIOGTYPE/FBIO_GETLINEWIDTH");
        return 1;
    }
    _ = syscall.ioctl(ufd, FBIO_GETRGBOFFS, @intFromPtr(&offs));
    if (t.fb_depth != 32) {
        libc.stdio.printf("fbdraw: %d bpp is not supported (32 only)\n", .{t.fb_depth});
        return 1;
    }

    const width: u64 = @intCast(t.fb_width);
    const height: u64 = @intCast(t.fb_height);
    const len: u64 = @as(u64, stride) * height;
    const base: i64 = syscall.mmapRaw(0, len, PROT_READ | PROT_WRITE, MAP_SHARED, ufd, 0);
    if (base < 0) {
        libc.stdio.puts("fbdraw: mmap failed");
        return 1;
    }

    libc.stdio.printf("fbdraw: %dx%d, %d bpp, %u bytes per line\n", .{ t.fb_width, t.fb_height, t.fb_depth, stride });
    _ = syscall.ioctl(0, KDSETMODE, KD_GRAPHICS);

    // A red/green gradient, with eight colour bars along the bottom.
    const fb: [*]u8 = @ptrFromInt(@as(u64, @intCast(base)));
    const bars: [8][3]u32 = .{
        .{ 255, 255, 255 }, .{ 255, 255, 0 }, .{ 0, 255, 255 }, .{ 0, 255, 0 },
        .{ 255, 0, 255 },   .{ 255, 0, 0 },   .{ 0, 0, 255 },   .{ 0, 0, 0 },
    };
    var y: u64 = 0;
    while (y < height) : (y += 1) {
        const row: [*]volatile u32 = @ptrCast(@alignCast(fb + y * stride));
        var x: u64 = 0;
        while (x < width) : (x += 1) {
            if (y >= height * 3 / 4) {
                const b = bars[x * 8 / width];
                row[x] = rgb(offs, b[0], b[1], b[2]);
            } else {
                const r: u32 = @intCast((x * 255) / width);
                const g: u32 = @intCast((y * 255) / height);
                row[x] = rgb(offs, r, g, 0x40);
            }
        }
    }

    // Wait for Enter, then hand the screen back to the console.
    var buf: [1]u8 = undefined;
    _ = syscall.read(0, &buf);
    _ = syscall.ioctl(0, KDSETMODE, KD_TEXT);
    libc.stdio.puts("fbdraw: done");
    return 0;
}
