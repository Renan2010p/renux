// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Minimal stdio.
//
// The Zig counterpart of NetBSD/FreeBSD lib/libc/stdio/printf.c, puts.c,
// putchar.c. Formatted output is compile-time checked: the format string is
// comptime, as in the kernel's subr_prf and in Zig's own std.fmt.

const syscall: type = @import("../sys/syscall.zig");

/// Write a byte string to a file descriptor.
fn writeFd(fd: u64, s: []const u8) void {
    _ = syscall.write(fd, s);
}

/// Emit one character on standard output.
pub fn putchar(c: u8) void {
    const one: [1]u8 = .{c};
    writeFd(1, &one);
}

/// Write a string followed by a newline to standard output.
pub fn puts(s: []const u8) void {
    writeFd(1, s);
    writeFd(1, "\n");
}

fn printUnsigned(value: u64, base: u64) void {
    if (value == 0) {
        putchar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v: u64 = value;
    while (v != 0) {
        const digit: u8 = @intCast(v % base);
        i -= 1;
        buf[i] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        v /= base;
    }
    writeFd(1, buf[i..]);
}

fn printSigned(value: i64) void {
    if (value < 0) {
        putchar('-');
        printUnsigned(@intCast(-value), 10);
    } else {
        printUnsigned(@intCast(value), 10);
    }
}

/// Formatted output to standard output. Supported conversions:
///
///   %%  literal percent     %c  character       %s  string
///   %d  signed decimal      %u  unsigned        %x  hexadecimal (0x-prefixed)
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    comptime var arg_index: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] != '%') {
            putchar(fmt[i]);
            i += 1;
        } else if (i + 1 == fmt.len) {
            putchar('%');
            i += 1;
        } else {
            const spec: u8 = fmt[i + 1];
            i += 2;
            switch (spec) {
                '%' => putchar('%'),
                'c' => putchar(@intCast(args[arg_index])),
                's' => writeFd(1, args[arg_index]),
                'u' => printUnsigned(@intCast(args[arg_index]), 10),
                'd' => printSigned(@intCast(args[arg_index])),
                'x' => {
                    writeFd(1, "0x");
                    printUnsigned(@intCast(args[arg_index]), 16);
                },
                else => {
                    putchar('%');
                    putchar(spec);
                },
            }
            if (spec != '%') {
                arg_index += 1;
            }
        }
    }
}
