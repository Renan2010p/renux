// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /bin/echo: write arguments to standard output.
//
// The Zig counterpart of the BSD echo(1), reduced to the common case (-n to
// suppress the trailing newline).

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

    var i: usize = 1;
    var newline: bool = true;
    if (argc > 1) {
        if (argv[1]) |a| {
            const s: []const u8 = zspan(a);
            if (s.len == 2 and s[0] == '-' and s[1] == 'n') {
                newline = false;
                i = 2;
            }
        }
    }

    var first: bool = true;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const a: [*:0]const u8 = argv[i] orelse continue;
        if (!first) {
            libc.stdio.putchar(' ');
        }
        first = false;
        libc.stdio.puts(zspan(a));
    }
    if (newline) {
        libc.stdio.putchar('\n');
    }
    return 0;
}
