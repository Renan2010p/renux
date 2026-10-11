// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// File status (stat(2)).
//
// This is the Zig counterpart of NetBSD's sys/sys/stat.h, reduced to the fields
// of struct stat that the current userland ABI uses.

/// File type bits for st_mode (S_IFMT and its values).
pub const S_IFMT: u32 = 0o170000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFBLK: u32 = 0o060000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFLNK: u32 = 0o120000;
pub const S_IFIFO: u32 = 0o010000;

/// The result of stat(2)/fstat(2) (NetBSD's struct stat, reduced). Declared
/// extern so its layout is the C ABI's and matches libc's copy exactly.
pub const Stat: type = extern struct {
    /// Device containing the file.
    dev: u64,
    /// File serial number (inode).
    ino: u64,
    /// File mode, including the type bits above.
    mode: u32,
    /// Number of hard links.
    nlink: u32,
    uid: u32,
    gid: u32,
    /// Device number, for special files.
    rdev: u64,
    /// Total size in bytes.
    size: u64,
    /// Optimal I/O block size.
    blksize: u64,
    /// Number of 512-byte blocks allocated.
    blocks: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
};
