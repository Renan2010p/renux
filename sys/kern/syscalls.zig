// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// System call implementations.
//
// This is the Zig counterpart of NetBSD's generated sys/kern/syscalls.c (and
// FreeBSD's syscalls.c): the table mapping system call numbers to handlers.
// NetBSD/FreeBSD generate it from syscalls.master; ZenBSD writes the table by
// hand until it has a generator.

const sys: type = @import("../sys/syscall.zig");
const cons: type = @import("../dev/cons.zig");
const arch: type = @import("../arch/arch.zig");
const prf: type = @import("subr_prf.zig");

/// A system call handler. `args` holds up to MAXARGS register arguments.
pub const Handler: type = *const fn (args: [sys.MAXARGS]u64) u64;

/// Error return value (a negative errno as unsigned).
pub const error_value: u64 = @bitCast(@as(i64, -1));

fn sysWrite(args: [sys.MAXARGS]u64) u64 {
    const fd: u64 = args[0];
    const buf: u64 = args[1];
    const count: u64 = args[2];
    if (fd != 1 and fd != 2) {
        return error_value;
    }

    // The user pages share the page tables with the kernel, so the buffer is
    // addressable directly. A copyin() path will replace this once user and
    // kernel address spaces are separated.
    const bytes: [*]const u8 = @ptrFromInt(buf);
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        cons.cnputc(bytes[i]);
    }
    return count;
}

fn sysRead(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0; // EOF; nobody feeds the console yet
}

fn sysExit(args: [sys.MAXARGS]u64) u64 {
    prf.print("init: exit(");
    prf.printDec(args[0]);
    prf.printLine(")");
    prf.printLine("ZenBSD: init(8) exited, halting");
    arch.cpu.idle();
}

/// Number-to-handler table, indexed by system call number.
pub const table: [8]?Handler = .{
    null, // 0
    sysExit, // 1
    null, // 2
    sysRead, // 3
    sysWrite, // 4
    null, // 5
    null, // 6
    null, // 7
};
