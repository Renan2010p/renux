// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/pwd: print the working directory.
//
// The Zig counterpart of the BSD pwd(1): print the path getcwd(2) returns.

const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;

    var buf: [1024]u8 = undefined;
    if (libc.syscall.getcwd(&buf) < 0) {
        libc.stdio.puts("pwd: cannot get cwd");
        return 1;
    }
    var n: usize = 0;
    while (buf[n] != 0) : (n += 1) {}
    libc.stdio.printf("%s\n", .{buf[0..n]});
    return 0;
}
