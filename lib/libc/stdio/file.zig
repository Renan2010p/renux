// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Buffered stdio streams.
//
// The Zig counterpart of NetBSD's lib/libc/stdio (FILE, fopen and friends),
// reduced to the calls the programs built so far use: reads are buffered,
// writes go straight to the descriptor.

const syscall: type = @import("../sys/syscall.zig");
const heap: type = @import("../stdlib/malloc.zig");

/// A stdio stream. `FILE *` in C points at one of these.
pub const File: type = struct {
    fd: c_int,
    eof: bool,
    err: bool,
    rlen: usize,
    rpos: usize,
    rbuf: [512]u8,
};

fn makeFile(fd: c_int) File {
    return .{ .fd = fd, .eof = false, .err = false, .rlen = 0, .rpos = 0, .rbuf = undefined };
}

var stdin_file: File = .{ .fd = 0, .eof = false, .err = false, .rlen = 0, .rpos = 0, .rbuf = undefined };
var stdout_file: File = .{ .fd = 1, .eof = false, .err = false, .rlen = 0, .rpos = 0, .rbuf = undefined };
var stderr_file: File = .{ .fd = 2, .eof = false, .err = false, .rlen = 0, .rpos = 0, .rbuf = undefined };

pub export var stdin: *File = &stdin_file;
pub export var stdout: *File = &stdout_file;
pub export var stderr: *File = &stderr_file;

/// Open `path` with the given `mode` ("r", "w" or "a").
pub export fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*File {
    var flags: c_int = syscall.O_RDONLY;
    switch (mode[0]) {
        'r' => flags = syscall.O_RDONLY,
        'w' => flags = syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC,
        'a' => flags = syscall.O_WRONLY | syscall.O_CREAT,
        else => return null,
    }
    const fd: i64 = syscall.open(path, @intCast(flags), 0);
    if (fd < 0) {
        return null;
    }
    const raw: ?*anyopaque = heap.malloc(@sizeOf(File)) orelse {
        _ = syscall.close(@intCast(fd));
        return null;
    };
    const f: *File = @ptrCast(@alignCast(raw));
    f.* = .{ .fd = @intCast(fd), .eof = false, .err = false, .rlen = 0, .rpos = 0, .rbuf = undefined };
    return f;
}

pub export fn fclose(f: *File) c_int {
    const err: i64 = syscall.close(@intCast(f.fd));
    heap.free(@ptrCast(f));
    return @intCast(err);
}

pub export fn fflush(f: ?*File) c_int {
    _ = f;
    return 0;
}

pub export fn fgetc(f: *File) c_int {
    if (f.rpos >= f.rlen) {
        const r: i64 = @bitCast(syscall.read(@intCast(f.fd), f.rbuf[0..]));
        if (r <= 0) {
            if (r == 0) {
                f.eof = true;
            } else {
                f.err = true;
            }
            return -1;
        }
        f.rlen = @intCast(r);
        f.rpos = 0;
    }
    const c: u8 = f.rbuf[f.rpos];
    f.rpos += 1;
    return c;
}

pub export fn fread(ptr: [*]u8, size: usize, nmemb: usize, f: *File) usize {
    const total: usize = size * nmemb;
    if (size == 0) {
        return 0;
    }
    var got: usize = 0;
    while (got < total) {
        if (f.rpos >= f.rlen) {
            const r: i64 = @bitCast(syscall.read(@intCast(f.fd), f.rbuf[0..]));
            if (r <= 0) {
                if (r == 0) {
                    f.eof = true;
                } else {
                    f.err = true;
                }
                break;
            }
            f.rlen = @intCast(r);
            f.rpos = 0;
        }
        while (f.rpos < f.rlen and got < total) : (got += 1) {
            ptr[got] = f.rbuf[f.rpos];
            f.rpos += 1;
        }
    }
    return got / size;
}

pub export fn fgets(s: [*]u8, n: usize, f: *File) ?[*]u8 {
    if (n == 0) {
        return null;
    }
    var i: usize = 0;
    while (i + 1 < n) {
        const c: c_int = fgetc(f);
        if (c < 0) {
            if (i == 0) {
                return null;
            }
            break;
        }
        s[i] = @intCast(c & 0xff);
        i += 1;
        if (s[i - 1] == '\n') {
            break;
        }
    }
    s[i] = 0;
    return s;
}

pub export fn fputc(c: c_int, f: *File) c_int {
    const byte: [1]u8 = .{@intCast(c & 0xff)};
    _ = syscall.write(@intCast(f.fd), &byte);
    return c & 0xff;
}

pub export fn fputs(s: [*:0]const u8, f: *File) c_int {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    _ = syscall.write(@intCast(f.fd), s[0..n]);
    return 0;
}

pub export fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *File) usize {
    const total: usize = size * nmemb;
    const r: i64 = @bitCast(syscall.write(@intCast(f.fd), ptr[0..total]));
    if (r <= 0) {
        f.err = true;
        return 0;
    }
    return @intCast(@divTrunc(r, @as(i64, @intCast(size))));
}

/// True when the stream reached end of file.
pub export fn feof(f: *File) c_int {
    return @intFromBool(f.eof);
}

/// True when the stream had an error.
pub export fn ferror(f: *File) c_int {
    return @intFromBool(f.err);
}

pub export fn fileno(f: *File) c_int {
    return f.fd;
}

pub export fn fseek(f: *File, off: c_long, whence: c_int) c_int {
    // Seeking discards the read buffer.
    f.rlen = 0;
    f.rpos = 0;
    const r: i64 = syscall.lseek(@intCast(f.fd), off, @intCast(whence));
    if (r < 0) {
        f.err = true;
        return -1;
    }
    f.eof = false;
    return 0;
}

pub export fn ftell(f: *File) c_long {
    const pos: i64 = syscall.lseek(@intCast(f.fd), 0, 1);
    const buffered: usize = f.rlen - f.rpos;
    return @intCast(pos - @as(i64, @intCast(buffered)));
}

pub export fn rewind(f: *File) void {
    _ = fseek(f, 0, 0);
}
