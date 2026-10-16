// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /usr/bin/logger: add a message to the system log.
//
// The Zig counterpart of FreeBSD's logger(1), reduced to its basic form: the
// arguments, joined by spaces, are written to the system log under the tag
// "logger".

const std: type = @import("std");
const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// Longest message; the rest is cut off.
const MESSAGE_MAX: usize = 256;

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;
    var buf: [MESSAGE_MAX]u8 = undefined;
    var len: usize = 0;
    for (1..@intCast(argc)) |i| {
        const word: []const u8 = std.mem.span(argv[i] orelse continue);
        if (len > 0 and len < buf.len) {
            buf[len] = ' ';
            len += 1;
        }
        const n: usize = @min(word.len, buf.len - len);
        @memcpy(buf[len..][0..n], word[0..n]);
        len += n;
    }
    libc.syslog.msg("logger", buf[0..len]);
    return 0;
}
