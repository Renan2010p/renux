// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
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

/// A time value (FreeBSD's struct timespec).
pub const Timespec: type = extern struct {
    sec: i64,
    nsec: i64,
};

/// The result of stat(2)/fstat(2), laid out like FreeBSD/amd64's struct stat so
/// that programs (and rtld-elf) built for the FreeBSD ABI read the right fields.
/// Declared extern so its layout is the C ABI's and matches libc's copy exactly.
pub const Stat: type = extern struct {
    /// Device containing the file.
    dev: u64,
    /// File serial number (inode).
    ino: u64,
    /// Number of hard links.
    nlink: u64,
    /// File mode, including the type bits above.
    mode: u16,
    padding0: i16,
    uid: u32,
    gid: u32,
    padding1: i32,
    /// Device number, for special files.
    rdev: u64,
    /// Access, modification and status-change times.
    atim: Timespec,
    mtim: Timespec,
    ctim: Timespec,
    /// Total size in bytes.
    size: i64,
    /// Number of 512-byte blocks allocated.
    blocks: i64,
    /// Optimal I/O block size.
    blksize: i32,
    /// User-defined flags (unused).
    flags: u32,
    /// File generation number (unused).
    gen: u32,
    lspare: u32,
    /// Creation time.
    birthtim: Timespec,
};
