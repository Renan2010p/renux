// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// System call numbers.
//
// NetBSD and FreeBSD both generate this from syscalls.master; ZenBSD lists the
// handful it implements today by hand. Numbers match the historical BSD values
// (exit = 1, read = 3, write = 4) so userland stubs are familiar.

pub const SYS_exit: u64 = 1;
pub const SYS_read: u64 = 3;
pub const SYS_write: u64 = 4;

/// Maximum argument count passed in registers.
pub const MAXARGS: usize = 6;
