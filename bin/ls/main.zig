// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /bin/ls: list directory contents.
//
// The Zig counterpart of the BSD ls(1), reduced to listing names (one per
// line) from a directory given on the command line or the root; it reads them
// with getdents(2).

const libc: type = @import("libc");
const Dirent: type = libc.syscall.Dirent;

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

const MAX_PATH: usize = 256;

/// A NUL-terminated string as a slice.
fn zspan(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return p[0..n];
}

/// Copy `s` into `buf` and NUL-terminate it.
fn cstr(s: []const u8, buf: []u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len) {
        return null;
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        buf[i] = s[i];
    }
    buf[s.len] = 0;
    return @ptrCast(&buf[0]);
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;

    var path: []const u8 = "/";
    if (argc >= 2) {
        if (argv[1]) |p| {
            path = zspan(p);
        }
    }

    var pb: [MAX_PATH]u8 = undefined;
    const cpath: [*:0]const u8 = cstr(path, &pb) orelse return 1;
    const fd: i64 = libc.syscall.open(cpath, libc.syscall.O_DIRECTORY, 0);
    if (fd < 0) {
        libc.stdio.printf("ls: %s: cannot open\n", .{path});
        return 1;
    }

    var buf: [512]u8 align(8) = undefined;
    while (true) {
        const n: u64 = libc.syscall.getdents(@intCast(fd), &buf);
        if (n == 0 or n > buf.len) {
            break;
        }
        var i: usize = 0;
        while (i + @sizeOf(Dirent) <= n) {
            const d: *const Dirent = @ptrCast(@alignCast(&buf[i]));
            const name_start: usize = i + @sizeOf(Dirent);
            const name: []const u8 = buf[name_start .. name_start + d.namlen];
            libc.stdio.printf("%s\n", .{name});
            if (d.reclen == 0) {
                break;
            }
            i += d.reclen;
        }
    }
    _ = libc.syscall.close(@intCast(fd));
    return 0;
}
