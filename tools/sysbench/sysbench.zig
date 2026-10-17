// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// sysbench: system call micro-benchmarks.
//
// A FreeBSD/amd64 program (built with `zig build-exe -target
// x86_64-freebsd -lc`), so the very same binary runs on FreeBSD and on Renux
// and the two kernels can be compared like for like. Each test times a loop of
// one operation with the CPU's time-stamp counter and prints the average cost
// in TSC cycles per operation (lower is better).

const std = @import("std");
const c = std.c;

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn report(name: []const u8, iters: u64, cycles: u64) void {
    std.debug.print("{s:<28} {d:>10} cycles/op  ({d} ops)\n", .{ name, cycles / iters, iters });
}

const BUF_SIZE = 4096;
var buf: [BUF_SIZE]u8 = undefined;

pub fn main() void {
    const path = "/tmp/sysbench.dat";

    // getpid(2): the cost of entering and leaving the kernel.
    {
        const n: u64 = 1_000_000;
        var i: u64 = 0;
        const t0 = rdtsc();
        while (i < n) : (i += 1) _ = c.getpid();
        report("getpid (null syscall)", n, rdtsc() - t0);
    }

    // A 64 KiB scratch file.
    {
        const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
        if (fd < 0) {
            std.debug.print("sysbench: cannot create {s}\n", .{path});
            return;
        }
        @memset(&buf, 'x');
        var k: usize = 0;
        while (k < 16) : (k += 1) _ = c.write(fd, &buf, buf.len);
        _ = c.close(fd);
    }

    // open(2) + close(2) of an existing file: path lookup and descriptors.
    {
        const n: u64 = 100_000;
        var i: u64 = 0;
        const t0 = rdtsc();
        while (i < n) : (i += 1) {
            const fd = c.open(path, .{ .ACCMODE = .RDONLY });
            _ = c.close(fd);
        }
        report("open+close", n, rdtsc() - t0);
    }

    // stat(2): path lookup and a copy-out of struct stat.
    {
        const n: u64 = 100_000;
        var st: c.Stat = undefined;
        var i: u64 = 0;
        const t0 = rdtsc();
        while (i < n) : (i += 1) _ = c.fstatat(c.AT.FDCWD, path, &st, 0);
        report("stat", n, rdtsc() - t0);
    }

    // pread(2) of 4 KiB from a cached file: data copy-out.
    {
        const fd = c.open(path, .{ .ACCMODE = .RDONLY });
        const n: u64 = 100_000;
        var i: u64 = 0;
        const t0 = rdtsc();
        while (i < n) : (i += 1) _ = c.pread(fd, &buf, BUF_SIZE, @intCast((i % 16) * BUF_SIZE));
        report("pread 4 KiB", n, rdtsc() - t0);
        _ = c.close(fd);
    }

    // write(2) + read(2) of one byte through a pipe.
    {
        var fds: [2]c.fd_t = undefined;
        if (c.pipe(&fds) == 0) {
            const n: u64 = 100_000;
            var one: [1]u8 = .{'p'};
            var i: u64 = 0;
            const t0 = rdtsc();
            while (i < n) : (i += 1) {
                _ = c.write(fds[1], &one, 1);
                _ = c.read(fds[0], &one, 1);
            }
            report("pipe write+read 1 B", n, rdtsc() - t0);
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
    }

    // fork(2) + _exit(2) + waitpid(2): process creation and teardown.
    {
        const n: u64 = 500;
        var i: u64 = 0;
        const t0 = rdtsc();
        while (i < n) : (i += 1) {
            const pid = c.fork();
            if (pid == 0) c._exit(0);
            var status: c_int = 0;
            _ = c.waitpid(pid, &status, 0);
        }
        report("fork+exit+wait", n, rdtsc() - t0);
    }

    _ = c.unlink(path);
}
