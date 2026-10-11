// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// System call numbers.
//
// NetBSD and FreeBSD both generate this from syscalls.master; ZenBSD lists the
// handful it implements today by hand. Numbers match the historical BSD values.

pub const SYS_exit: u64 = 1;
pub const SYS_fork: u64 = 2;
pub const SYS_read: u64 = 3;
pub const SYS_write: u64 = 4;
pub const SYS_open: u64 = 5;
pub const SYS_close: u64 = 6;
pub const SYS_wait4: u64 = 7;
pub const SYS_unlink: u64 = 10;
pub const SYS_chdir: u64 = 12;
pub const SYS_lseek: u64 = 19;
pub const SYS_getpid: u64 = 20;
pub const SYS_dup: u64 = 41;
pub const SYS_execve: u64 = 59;
pub const SYS_fstat: u64 = 62;
pub const SYS_dup2: u64 = 90;
pub const SYS_mkdir: u64 = 136;
pub const SYS_rmdir: u64 = 137;
pub const SYS_stat: u64 = 188;
pub const SYS_getdents: u64 = 390;
pub const SYS_getcwd: u64 = 418;

/// Maximum argument count passed in registers.
pub const MAXARGS: usize = 6;

/// Highest system call number plus one.
pub const MAXSYSCALL: usize = 512;

/// Error return value (a negative errno as unsigned).
pub const ERROR: u64 = @bitCast(@as(i64, -1));

/// Reinterpret a signed value as the unsigned system call result.
pub fn signed(value: i64) u64 {
    return @bitCast(value);
}
