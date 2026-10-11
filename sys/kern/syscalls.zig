// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// System call implementations.
//
// The Zig counterpart of NetBSD's generated syscalls.c: the table mapping
// system call numbers to handlers, plus the process-management calls that make
// the system usable (fork, execve, wait, exit, getpid).

const sys: type = @import("../sys/syscall.zig");
const cons: type = @import("../dev/cons.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_fork: type = @import("kern_fork.zig");
const kern_exit: type = @import("kern_exit.zig");
const kern_exec: type = @import("kern_exec.zig");
const prf: type = @import("subr_prf.zig");

/// A system call handler. `args` holds up to MAXARGS register arguments.
pub const Handler: type = *const fn (args: [sys.MAXARGS]u64) u64;

/// Error return value (a negative errno as unsigned).
pub const error_value: u64 = @bitCast(@as(i64, -1));

fn signed(value: i64) u64 {
    return @bitCast(value);
}

fn sysWrite(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];
    if (fd != 1 and fd != 2) {
        return error_value;
    }
    const bytes: [*]const u8 = @ptrFromInt(buf);
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        cons.cnputc(bytes[i]);
    }
    return count;
}

fn sysRead(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];
    if (fd != 0 or count == 0) {
        return 0;
    }
    // Block for one byte; the console read leaves interrupts enabled so the
    // scheduler can run other processes.
    const c: u8 = cons.cngetc();
    const dst: [*]u8 = @ptrFromInt(buf);
    dst[0] = c;
    return 1;
}

fn sysExit(args: [sys.MAXARGS]u64) u64 {
    const status: i32 = @bitCast(@as(u32, @truncate(args[0])));
    kern_exit.exit(status);
}

fn sysFork(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    const frame = arch.trap.currentFrame() orelse return error_value;
    return signed(kern_fork.fork(frame));
}

fn sysWait(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    var status: i32 = 0;
    return signed(kern_exit.wait(&status));
}

fn sysGetpid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.pid);
}

fn sysExecve(args: [sys.MAXARGS]u64) u64 {
    const path_ptr: u64 = args[0];
    const frame = arch.trap.currentFrame() orelse return error_value;
    const path: [*:0]const u8 = @ptrFromInt(path_ptr);
    return signed(kern_exec.execve(frame, path));
}

/// Number-to-handler table, indexed by system call number.
pub const table: [sys.MAXSYSCALL]?Handler = .{
    null, // 0
    sysExit, // 1
    sysFork, // 2
    sysRead, // 3
    sysWrite, // 4
    null, // 5
    null, // 6
    sysWait, // 7
    null, // 8
    null, // 9
    null, // 10
    null, // 11
    null, // 12
    null, // 13
    null, // 14
    null, // 15
    null, // 16
    null, // 17
    null, // 18
    null, // 19
    sysGetpid, // 20
    null, // 21
    null, // 22
    null, // 23
    null, // 24
    null, // 25
    null, // 26
    null, // 27
    null, // 28
    null, // 29
    null, // 30
    null, // 31
    null, // 32
    null, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    null, // 50
    null, // 51
    null, // 52
    null, // 53
    null, // 54
    null, // 55
    null, // 56
    null, // 57
    null, // 58
    sysExecve, // 59
    null, // 60
    null, // 61
    null, // 62
    null, // 63
};
