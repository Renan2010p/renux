// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /sbin/init: the first user process.
//
// Machine-independent userland. It reaches the kernel only through the int 0x80
// system call interface (number in rax, arguments in rdi/rsi/rdx/r10/r8/r9,
// result in rax). For now it writes a greeting and exits.

const SYS_exit: u64 = 1;
const SYS_write: u64 = 4;

/// Issue a three-argument system call.
fn syscall3(number: u64, a0: u64, a1: u64, a2: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (number),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : .{ .memory = true });
}

fn write(fd: u64, buf: [*]const u8, len: u64) u64 {
    return syscall3(SYS_write, fd, @intFromPtr(buf), len);
}

fn exit(code: u64) noreturn {
    _ = syscall3(SYS_exit, code, 0, 0);
    unreachable;
}

const greeting: []const u8 = "hello from userland\n";

export fn _start() callconv(.c) noreturn {
    _ = write(1, greeting.ptr, greeting.len);
    exit(0);
}
