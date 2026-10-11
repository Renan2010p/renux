// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C library interface.
//
// C ABI wrappers around the Zig libc, so a C program compiled against the
// headers in lib/include links against the same implementation the Zig
// programs use. Each export is a thin adapter over the corresponding Zig
// function (the C `ssize_t`/`int` result type, a NUL-terminated string in place
// of a slice).

const syscall: type = @import("sys/syscall.zig");
const stdio: type = @import("stdio/stdio.zig");

/// Length of a NUL-terminated C string.
fn span(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return p[0..n];
}

pub export fn write(fd: c_int, buf: [*]const u8, n: usize) isize {
    const r: i64 = @bitCast(syscall.write(@intCast(fd), buf[0..n]));
    return @intCast(r);
}

pub export fn read(fd: c_int, buf: [*]u8, n: usize) isize {
    const r: i64 = @bitCast(syscall.read(@intCast(fd), buf[0..n]));
    return @intCast(r);
}

pub export fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    _ = mode;
    const r: i64 = syscall.open(path, @intCast(flags), 0);
    return @intCast(r);
}

pub export fn close(fd: c_int) c_int {
    const r: i64 = syscall.close(@intCast(fd));
    return @intCast(r);
}

pub export fn lseek(fd: c_int, off: i64, whence: c_int) i64 {
    return syscall.lseek(@intCast(fd), off, @intCast(whence));
}

pub export fn chdir(path: [*:0]const u8) c_int {
    return @intCast(syscall.chdir(path));
}

pub export fn mkdir(path: [*:0]const u8, mode: c_int) c_int {
    return @intCast(syscall.mkdir(path, @intCast(mode & 0o777)));
}

pub export fn rmdir(path: [*:0]const u8) c_int {
    return @intCast(syscall.rmdir(path));
}

pub export fn unlink(path: [*:0]const u8) c_int {
    return @intCast(syscall.unlink(path));
}

pub export fn getpid() c_int {
    return syscall.getpid();
}

pub export fn _exit(status: c_int) noreturn {
    syscall.exit(@intCast(status));
}

pub export fn puts(s: [*:0]const u8) c_int {
    stdio.puts(span(s));
    return 0;
}

pub export fn putchar(c: c_int) c_int {
    stdio.putchar(@intCast(c & 0xff));
    return c & 0xff;
}

pub export fn getchar() c_int {
    return stdio.getchar();
}
