// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Error numbers.
//
// This is the Zig counterpart of NetBSD's sys/sys/errno.h, limited to the
// values returned by the interfaces implemented so far. The numbers match the
// traditional BSD values, which are also the ones userland expects.

pub const EPERM: i32 = 1;
pub const ENOENT: i32 = 2;
pub const ESRCH: i32 = 3;
pub const EINTR: i32 = 4;
pub const EIO: i32 = 5;
pub const ENXIO: i32 = 6;
pub const E2BIG: i32 = 7;
pub const ENOEXEC: i32 = 8;
pub const EBADF: i32 = 9;
pub const ECHILD: i32 = 10;
pub const EDEADLK: i32 = 11; // resource deadlock avoided
pub const EAGAIN: i32 = 35; // resource temporarily unavailable (FreeBSD; 11 is Linux)
pub const ENOMEM: i32 = 12;
pub const EACCES: i32 = 13;
pub const EFAULT: i32 = 14;
pub const EBUSY: i32 = 16;
pub const EEXIST: i32 = 17;
pub const EXDEV: i32 = 18;
pub const ENODEV: i32 = 19;
pub const ENOTDIR: i32 = 20;
pub const EISDIR: i32 = 21;
pub const EINVAL: i32 = 22;
pub const ENFILE: i32 = 23;
pub const EMFILE: i32 = 24;
pub const ENOTTY: i32 = 25;
pub const ENOSPC: i32 = 28;
pub const ESPIPE: i32 = 29;
pub const EROFS: i32 = 30;
pub const EPIPE: i32 = 32;
pub const EMLINK: i32 = 31;
pub const ENAMETOOLONG: i32 = 63;
pub const ENOTEMPTY: i32 = 66;
pub const EOPNOTSUPP: i32 = 45;
pub const ENOSYS: i32 = 78;
pub const ERANGE: i32 = 34; // result too large
