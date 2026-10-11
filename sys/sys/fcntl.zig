// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Open flags.
//
// This is the Zig counterpart of the open(2) half of NetBSD's sys/sys/fcntl.h,
// reduced to the flags open(2) accepts. The values are the traditional BSD
// ones.

/// Mask selecting the access mode.
pub const O_ACCMODE: i32 = 0x0003;
pub const O_RDONLY: i32 = 0x0000;
pub const O_WRONLY: i32 = 0x0001;
pub const O_RDWR: i32 = 0x0002;

pub const O_NONBLOCK: i32 = 0x0004;
pub const O_APPEND: i32 = 0x0008;
pub const O_CREAT: i32 = 0x0200;
pub const O_TRUNC: i32 = 0x0400;
pub const O_EXCL: i32 = 0x0800;
pub const O_DIRECTORY: i32 = 0x20000;

/// F_* commands for fcntl(2) (kept minimal).
pub const F_DUPFD: i32 = 0;
pub const F_GETFD: i32 = 1;
pub const F_SETFD: i32 = 2;
pub const F_GETFL: i32 = 3;
pub const F_SETFL: i32 = 4;

/// Descriptor flags.
pub const FD_CLOEXEC: i32 = 1;
