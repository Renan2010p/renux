// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /bin/cat: concatenate files to standard output.
//
// The Zig counterpart of the BSD cat(1), reduced to the common case: copy the
// named files (or an error when none are given) to descriptor 1.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// A NUL-terminated string as a slice.
fn zspan(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return p[0..n];
}

fn cat(path: [*:0]const u8) void {
    const fd: i64 = libc.syscall.open(path, libc.syscall.O_RDONLY, 0);
    if (fd < 0) {
        libc.stdio.printf("cat: %s: cannot open\n", .{zspan(path)});
        return;
    }
    var buf: [256]u8 = undefined;
    while (true) {
        const n: u64 = libc.syscall.read(@intCast(fd), &buf);
        if (n == 0 or n > buf.len) {
            break;
        }
        _ = libc.syscall.write(1, buf[0..@intCast(n)]);
    }
    _ = libc.syscall.close(@intCast(fd));
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;
    if (argc < 2) {
        return 1;
    }
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const path: [*:0]const u8 = argv[i] orelse continue;
        cat(path);
    }
    return 0;
}
