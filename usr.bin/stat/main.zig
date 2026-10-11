// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// /bin/stat: report file status.
//
// The Zig counterpart of the BSD stat(1), reduced to the fields struct stat
// carries here; it uses stat(2) rather than open(2).

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
        return 1;
    }
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const path: [*:0]const u8 = argv[i] orelse continue;
        var st: libc.syscall.Stat = undefined;
        if (libc.syscall.stat(path, &st) < 0) {
            libc.stdio.printf("stat: %s: cannot stat\n", .{zspan(path)});
            continue;
        }
        libc.stdio.printf("%s: mode %d nlink %d size %d\n", .{ zspan(path), st.mode, st.nlink, st.size });
    }
    return 0;
}
