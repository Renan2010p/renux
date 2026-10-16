// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/dmesg: print the kernel message buffer.
//
// The Zig counterpart of FreeBSD's dmesg(8), reduced to its default action:
// copy the kernel's message buffer (read with the klog system call) to
// standard output.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// The kernel message buffer is at most this large.
const MSGBUF_SIZE: usize = 16384;

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;
    var buf: [MSGBUF_SIZE]u8 = undefined;
    const len: i64 = libc.syscall.klogRaw(&buf);
    if (len < 0) {
        libc.stdio.puts("dmesg: cannot read the message buffer");
        return 1;
    }
    _ = libc.syscall.write(1, buf[0..@intCast(len)]);
    return 0;
}
