// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/hello: exercise the Renux C library.
//
// A smoke test of the native libc on a running system: each line it prints
// shows one part working (the heap, formatted output, stdio streams with
// seeking, the terminal, errno). It takes no arguments.

const std: type = @import("std");
const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// A file every Renux root has.
const SAMPLE_FILE: [*:0]const u8 = "/etc/fstab";
/// A file no Renux root has, to provoke ENOENT.
const MISSING_FILE: [*:0]const u8 = "/nonexistent";

/// lseek/fseek origin: the end of the file.
const SEEK_END: c_int = 2;

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;

    // The heap.
    const raw: ?*anyopaque = libc.c.malloc(64);
    if (raw) |memory| {
        const text: []u8 = @as([*]u8, @ptrCast(memory))[0..64];
        const message: []const u8 = "the heap works";
        @memcpy(text[0..message.len], message);
        libc.stdio.printf("hello from Zig on Renux: %s\n", .{text[0..message.len]});
        libc.c.free(memory);
    }

    // Formatting into a buffer.
    var buf: [64]u8 = undefined;
    const formatted: []const u8 = std.fmt.bufPrint(&buf, "bufPrint:{d}/{s}", .{ 7, "ok" }) catch "bufPrint failed";
    libc.stdio.printf("%s\n", .{formatted});

    // The terminal.
    libc.stdio.printf("isatty(0)=%d\n", .{libc.termios.isatty(0)});

    // A stdio stream, with seeking.
    if (libc.file.fopen(SAMPLE_FILE, "r")) |stream| {
        _ = libc.file.fseek(stream, 0, SEEK_END);
        libc.stdio.printf("%s size=%d\n", .{ std.mem.span(SAMPLE_FILE), libc.file.ftell(stream) });
        _ = libc.file.fclose(stream);
    }

    // errno and strerror.
    if (libc.file.fopen(MISSING_FILE, "r") == null) {
        libc.stdio.printf("%s: %s\n", .{ std.mem.span(MISSING_FILE), std.mem.span(libc.errno.strerror(libc.errno.ENOENT)) });
    }
    return 0;
}
