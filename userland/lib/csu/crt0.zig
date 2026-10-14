// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Userland startup.
//
// This is the Zig counterpart of NetBSD's lib/csu (FreeBSD's lib/csu), split
// out of the C library as a separate piece the linker starts the program with.
// Following the FreeBSD process-entry convention, the kernel enters the program
// with %rdi pointing at argc on the initial stack; argv and envp follow it.
// Startup hands them to main() and exits with main's result.

const libc: type = @import("libc");

/// The program's main routine, provided by the program itself.
extern fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32;

/// Process entry point (the ELF entry). `sp` points at argc; argv is the
/// NUL-terminated vector after it, envp the vector after that. Never returns.
pub export fn _start(sp: [*]const u64) callconv(.c) noreturn {
    const argc: usize = @intCast(sp[0]);
    const argv: [*]?[*:0]const u8 = @ptrFromInt(@intFromPtr(sp) + @sizeOf(u64));
    const envp: [*]?[*:0]const u8 = @ptrFromInt(@intFromPtr(sp) + @sizeOf(u64) * (argc + 2));

    libc.c.setEnviron(envp);
    const status: i32 = main(@intCast(argc), argv, envp);
    libc.syscall.exit(@as(u64, @bitCast(@as(i64, status))));
    unreachable;
}
