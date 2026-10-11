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
pub const SYS_lseek: u64 = 19;
pub const SYS_getpid: u64 = 20;
pub const SYS_execve: u64 = 59;
pub const SYS_fstat: u64 = 62;

/// Maximum argument count passed in registers.
pub const MAXARGS: usize = 6;

/// Highest system call number plus one.
pub const MAXSYSCALL: usize = 64;
