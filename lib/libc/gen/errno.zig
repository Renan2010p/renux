// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// errno and strerror.
//
// The Zig counterpart of NetBSD's lib/libc/gen/errno.c and strerror.c: the
// per-process error number a failing call records, and its message.

/// The last error. `extern int errno` in C.
pub export var errno: c_int = 0;

pub const EPERM: c_int = 1;
pub const ENOENT: c_int = 2;
pub const EIO: c_int = 5;
pub const EBADF: c_int = 9;
pub const EAGAIN: c_int = 11;
pub const ENOMEM: c_int = 12;
pub const EACCES: c_int = 13;
pub const EFAULT: c_int = 14;
pub const EEXIST: c_int = 17;
pub const ENOTDIR: c_int = 20;
pub const EISDIR: c_int = 21;
pub const EINVAL: c_int = 22;
pub const ENFILE: c_int = 23;
pub const EMFILE: c_int = 24;
pub const ENOTTY: c_int = 25;
pub const ENOSPC: c_int = 28;
pub const ESPIPE: c_int = 29;
pub const EROFS: c_int = 30;
pub const ENAMETOOLONG: c_int = 63;
pub const ENOTEMPTY: c_int = 66;
pub const EOPNOTSUPP: c_int = 45;

/// Record `value` as the error and return -1 (the usual C failure result).
pub fn set(value: c_int) c_int {
    errno = value;
    return -1;
}

pub export fn strerror(code: c_int) [*:0]const u8 {
    return switch (code) {
        EPERM => "operation not permitted",
        ENOENT => "no such file or directory",
        EIO => "input/output error",
        EBADF => "bad file descriptor",
        EAGAIN => "resource temporarily unavailable",
        ENOMEM => "cannot allocate memory",
        EACCES => "permission denied",
        EFAULT => "bad address",
        EEXIST => "file exists",
        ENOTDIR => "not a directory",
        EISDIR => "is a directory",
        EINVAL => "invalid argument",
        ENFILE => "too many open files in system",
        EMFILE => "too many open files",
        ENOTTY => "inappropriate ioctl for device",
        ENOSPC => "no space left on device",
        ESPIPE => "illegal seek",
        EROFS => "read-only file system",
        ENAMETOOLONG => "file name too long",
        ENOTEMPTY => "directory not empty",
        EOPNOTSUPP => "operation not supported",
        else => "unknown error",
    };
}
