// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/mkdir: make directories.
//
// The Zig counterpart of the BSD mkdir(1), reduced to mkdir(2) with a fixed
// mode.

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

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;
    if (argc < 2) {
        libc.stdio.puts("mkdir: missing operand");
        return 1;
    }

    var rc: i32 = 0;
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const path: [*:0]const u8 = argv[i] orelse continue;
        if (libc.syscall.mkdir(path, 0o755) < 0) {
            libc.stdio.printf("mkdir: %s: cannot create\n", .{zspan(path)});
            rc = 1;
        }
    }
    return rc;
}
