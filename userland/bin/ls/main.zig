// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/ls: list the contents of a directory.
//
// The Zig counterpart of FreeBSD's ls(1), reduced to its two common forms:
//
//   ls [dir]       one name per line
//   ls -l [dir]    the size (right-aligned in 8 columns) and the name
//
// The directory defaults to "/". Entries are listed in directory order.

const std: type = @import("std");
const libc: type = @import("libc");

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// Width of the size column of `ls -l`.
const SIZE_WIDTH: usize = 8;

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;
    const args: []const ?[*:0]const u8 = argv[1..@intCast(argc)];
    var next: usize = 0;
    var long_format: bool = false;
    if (next < args.len and std.mem.eql(u8, std.mem.span(args[next].?), "-l")) {
        long_format = true;
        next += 1;
    }
    const path: [*:0]const u8 = if (next < args.len) args[next].? else "/";

    const dir: *libc.dirent.DIR = libc.dirent.opendir(path) orelse {
        libc.stdio.printf("ls: cannot open %s\n", .{std.mem.span(path)});
        return 1;
    };
    defer _ = libc.dirent.closedir(dir);

    while (libc.dirent.readdir(dir)) |entry| {
        const name: []const u8 = entry.d_name[0..entry.d_namlen];
        if (long_format) {
            printSize(std.mem.span(path), name);
            libc.stdio.printf(" %s\n", .{name});
        } else {
            libc.stdio.printf("%s\n", .{name});
        }
    }
    return 0;
}

/// Print the size of `dir`/`name`, right-aligned, or "?" when it cannot be
/// read.
fn printSize(dir: []const u8, name: []const u8) void {
    var path_buf: [512]u8 = undefined;
    var text_buf: [24]u8 = undefined;
    const text: []const u8 = blk: {
        const full: [:0]const u8 = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dir, name }, 0) catch break :blk "?";
        var st: libc.syscall.Stat = undefined;
        if (libc.syscall.stat(full.ptr, &st) != 0) break :blk "?";
        break :blk std.fmt.bufPrint(&text_buf, "{d}", .{st.size}) catch "?";
    };
    for (text.len..SIZE_WIDTH) |_| libc.stdio.putchar(' ');
    libc.stdio.printf("%s", .{text});
}
