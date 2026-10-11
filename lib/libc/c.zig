// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
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
const heap: type = @import("stdlib/malloc.zig");
const string: type = @import("string/string.zig");
const ctype: type = @import("ctype/ctype.zig");
const getenv_: type = @import("stdlib/getenv.zig");
const errno_: type = @import("gen/errno.zig");

comptime {
    // These files export their C symbols; reference them so they are emitted.
    _ = @import("stdio/cprintf.zig");
    _ = @import("stdio/file.zig");
    _ = @import("gen/dirent.zig");
    _ = @import("gen/termios.zig");
    _ = @import("gen/getopt.zig");
    _ = @import("gen/syslog.zig");
    _ = @import("gen/time.zig");
    _ = @import("termcap/termcap.zig");
    _ = @import("curses/curses.zig");
    _ = getenv_;
    _ = errno_;
}

/// Record the errno from a failing syscall (which returned a negative errno)
/// and return -1.
fn cerr(neg: i64) c_int {
    return errno_.set(@intCast(-neg));
}

/// Length of a NUL-terminated C string.
fn span(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return p[0..n];
}

pub export fn write(fd: c_int, buf: [*]const u8, n: usize) isize {
    const r: i64 = @bitCast(syscall.write(@intCast(fd), buf[0..n]));
    if (r < 0) {
        return @intCast(cerr(r));
    }
    return @intCast(r);
}

pub export fn read(fd: c_int, buf: [*]u8, n: usize) isize {
    const r: i64 = @bitCast(syscall.read(@intCast(fd), buf[0..n]));
    if (r < 0) {
        return @intCast(cerr(r));
    }
    return @intCast(r);
}

pub export fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    _ = mode;
    const r: i64 = syscall.open(path, @intCast(flags), 0);
    if (r < 0) {
        return cerr(r);
    }
    return @intCast(r);
}

pub export fn close(fd: c_int) c_int {
    const r: i64 = syscall.close(@intCast(fd));
    if (r < 0) {
        return cerr(r);
    }
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

pub export fn getuid() c_int {
    return @intCast(syscall.getuidRaw());
}

pub export fn setuid(uid: c_int) c_int {
    const r: i64 = syscall.setuid(@intCast(uid));
    if (r < 0) {
        return cerr(r);
    }
    return 0;
}

pub export fn klog(buf: [*]u8, len: usize) isize {
    const r: i64 = syscall.klogRaw(buf[0..len]);
    if (r < 0) {
        return @intCast(cerr(r));
    }
    return @intCast(r);
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

pub export fn malloc(size: usize) ?*anyopaque {
    return heap.malloc(size);
}

pub export fn free(ptr: ?*anyopaque) void {
    heap.free(ptr);
}

pub export fn calloc(n: usize, size: usize) ?*anyopaque {
    return heap.calloc(n, size);
}

pub export fn memcpy(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    return string.memcpy(dst, src, n);
}

pub export fn memset(dst: [*]u8, c: c_int, n: usize) [*]u8 {
    return string.memset(dst, @intCast(c & 0xff), n);
}

pub export fn memmove(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    return string.memmove(dst, src, n);
}

pub export fn strlen(s: [*:0]const u8) usize {
    return string.strlen(s);
}

pub export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    return string.strcmp(a, b);
}

pub export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) c_int {
    return string.strncmp(a, b, n);
}

pub export fn strcpy(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    return string.strcpy(dst, src);
}

pub export fn strncpy(dst: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    return string.strncpy(dst, src, n);
}

pub export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]u8 {
    return string.strchr(s, @intCast(c & 0xff));
}

pub export fn strcat(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    return string.strcat(dst, src);
}

pub export fn isdigit(c: c_int) c_int {
    return ctype.isdigit(c);
}

pub export fn isspace(c: c_int) c_int {
    return ctype.isspace(c);
}

pub export fn isalpha(c: c_int) c_int {
    return ctype.isalpha(c);
}

pub export fn isalnum(c: c_int) c_int {
    return ctype.isalnum(c);
}

pub export fn isupper(c: c_int) c_int {
    return ctype.isupper(c);
}

pub export fn islower(c: c_int) c_int {
    return ctype.islower(c);
}

pub export fn isxdigit(c: c_int) c_int {
    return ctype.isxdigit(c);
}

pub export fn toupper(c: c_int) c_int {
    return ctype.toupper(c);
}

pub export fn tolower(c: c_int) c_int {
    return ctype.tolower(c);
}

pub export fn atoi(s: [*:0]const u8) c_int {
    var i: usize = 0;
    var sign: c_int = 1;
    while (s[i] == ' ' or s[i] == '\t' or s[i] == '\n') : (i += 1) {}
    if (s[i] == '-') {
        sign = -1;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }
    var v: c_int = 0;
    while (s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + @as(c_int, s[i] - '0');
    }
    return v * sign;
}

pub export fn exit(status: c_int) noreturn {
    syscall.exit(@intCast(status));
}

pub export fn abort() noreturn {
    syscall.exit(134);
}

/// Record the environment vector for getenv().
pub fn setEnviron(envp: [*]?[*:0]const u8) void {
    getenv_.setEnviron(envp);
}

pub export fn getenv(name: [*:0]const u8) ?[*:0]u8 {
    return getenv_.getenvRaw(name);
}

pub export fn mmap(addr: u64, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) ?*anyopaque {
    const r: i64 = syscall.mmapRaw(addr, @intCast(len), @intCast(prot), @intCast(flags), @intCast(fd), @bitCast(off));
    if (r < 0) {
        return null;
    }
    return @ptrFromInt(@as(u64, @intCast(r)));
}

pub export fn munmap(addr: ?*anyopaque, len: usize) c_int {
    const a: u64 = if (addr) |p| @intFromPtr(p) else 0;
    return @intCast(syscall.munmap(a, @intCast(len)));
}

pub export fn time(t: ?*i64) i64 {
    var tv: syscall.Timeval = .{ .tv_sec = 0, .tv_usec = 0 };
    _ = syscall.gettimeofdayRaw(&tv);
    if (t) |p| {
        p.* = tv.tv_sec;
    }
    return tv.tv_sec;
}

pub export fn gettimeofday(tv: ?*syscall.Timeval, tz: ?*anyopaque) c_int {
    _ = tz;
    if (tv) |p| {
        return @intCast(syscall.gettimeofdayRaw(p));
    }
    return 0;
}

pub export fn stat(path: [*:0]const u8, buf: *syscall.Stat) c_int {
    const r: i64 = syscall.stat(path, buf);
    if (r < 0) {
        return cerr(r);
    }
    return 0;
}

pub export fn fstat(fd: c_int, buf: *syscall.Stat) c_int {
    const r: i64 = syscall.fstat(@intCast(fd), buf);
    if (r < 0) {
        return cerr(r);
    }
    return 0;
}

pub export fn signal(sig: c_int, handler: usize) usize {
    return syscall.signal(@intCast(sig), handler);
}

pub export fn sigaction(sig: c_int, act: ?*const syscall.Sigaction, oact: ?*syscall.Sigaction) c_int {
    const r: i64 = syscall.sigaction(@intCast(sig), act, oact);
    if (r < 0) {
        return cerr(r);
    }
    return 0;
}
