// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/fbdraw: paint the framebuffer through /dev/fb0.
//
// A bring-up test for the framebuffer device: open /dev/fb0, map it, and fill
// the screen with a gradient. This is the same path a graphical server's
// scfb(4) driver takes (ioctl FBIOGTYPE + mmap).

const libc: type = @import("libc");
const syscall: type = libc.syscall;

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// Assumed panel geometry (matches the QEMU/Limine framebuffer).
const WIDTH: u64 = 1024;
const HEIGHT: u64 = 768;

// mmap(2) constants (FreeBSD).
const PROT_READ: u64 = 0x1;
const PROT_WRITE: u64 = 0x2;
const MAP_SHARED: u64 = 0x1;
// open(2) flag.
const O_RDWR: u64 = 0x2;

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;

    const fd: i64 = syscall.open("/dev/fb0", O_RDWR, 0);
    if (fd < 0) {
        libc.stdio.puts("fbdraw: cannot open /dev/fb0");
        return 1;
    }

    const len: u64 = WIDTH * HEIGHT * 4;
    const base: i64 = syscall.mmapRaw(0, len, PROT_READ | PROT_WRITE, MAP_SHARED, @intCast(fd), 0);
    if (base < 0) {
        libc.stdio.puts("fbdraw: mmap failed");
        return 1;
    }

    const px: [*]volatile u32 = @ptrFromInt(@as(u64, @intCast(base)));
    var y: u64 = 0;
    while (y < HEIGHT) : (y += 1) {
        var x: u64 = 0;
        while (x < WIDTH) : (x += 1) {
            const r: u32 = @intCast((x * 255) / WIDTH);
            const g: u32 = @intCast((y * 255) / HEIGHT);
            px[y * WIDTH + x] = 0xff000000 | (r << 16) | (g << 8);
        }
    }

    libc.stdio.puts("fbdraw: painted /dev/fb0");
    return 0;
}
