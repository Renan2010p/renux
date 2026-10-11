// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Userland startup.
//
// This is the Zig counterpart of NetBSD's lib/csu (FreeBSD's lib/csu), split
// out of the C library as a separate piece the linker starts the program with.
// The kernel passes argc, argv and envp in the first three argument registers,
// so startup simply hands them to main() and exits with main's result. The
// stack they point at is also laid out the traditional way, so getenv(3) and
// friends can find it later.

const libc: type = @import("libc");

/// The program's main routine, provided by the program itself.
extern fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32;

/// Process entry point (the ELF entry). Never returns.
pub export fn _start(argc: u64, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) noreturn {
    const status: i32 = main(@intCast(argc), argv, envp);
    libc.syscall.exit(@as(u64, @bitCast(@as(i64, status))));
    unreachable;
}
