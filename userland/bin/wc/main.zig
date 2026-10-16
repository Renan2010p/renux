// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/wc: count the lines, words and bytes of a file.
//
// The Zig counterpart of FreeBSD's wc(1), reduced to one file and the
// default report: "<lines> <words> <bytes> <file>". A word is a run of
// characters other than space, tab and newline.

const std: type = @import("std");
const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// The three counts wc reports.
const Counts: type = struct {
    lines: u64 = 0,
    words: u64 = 0,
    bytes: u64 = 0,
    in_word: bool = false,

    /// Count the bytes of `chunk`.
    fn add(counts: *Counts, chunk: []const u8) void {
        counts.bytes += chunk.len;
        for (chunk) |c| {
            switch (c) {
                '\n', ' ', '\t' => {
                    if (c == '\n') counts.lines += 1;
                    counts.in_word = false;
                },
                else => if (!counts.in_word) {
                    counts.in_word = true;
                    counts.words += 1;
                },
            }
        }
    }
};

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;
    if (argc < 2) {
        libc.stdio.puts("usage: wc file");
        return 1;
    }
    const path: [*:0]const u8 = argv[1] orelse return 1;
    const fd: i64 = libc.syscall.open(path, libc.syscall.O_RDONLY, 0);
    if (fd < 0) {
        libc.stdio.printf("wc: cannot open %s\n", .{std.mem.span(path)});
        return 1;
    }
    defer _ = libc.syscall.close(@intCast(fd));

    var counts: Counts = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n: u64 = libc.syscall.read(@intCast(fd), &buf);
        // read returns a negative errno as a huge unsigned value.
        if (n == 0 or n > buf.len) break;
        counts.add(buf[0..@intCast(n)]);
    }
    libc.stdio.printf("%u %u %u %s\n", .{ counts.lines, counts.words, counts.bytes, std.mem.span(path) });
    return 0;
}
