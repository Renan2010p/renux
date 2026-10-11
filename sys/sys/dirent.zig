// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Directory entries.
//
// This is the Zig counterpart of NetBSD's sys/sys/dirent.h: the on-the-wire
// struct dirent returned by getdents(2). The name follows the fixed header
// inline and is NUL-terminated, padded so each record starts on an eight-byte
// boundary.

/// Directory entry header; the name bytes follow immediately after it.
pub const Dirent: type = struct {
    /// File serial number (inode).
    ino: u64,
    /// Offset of the next entry, for telldir/seekdir.
    off: i64,
    /// Length of this record, in bytes.
    reclen: u16,
    /// File type (DT_* below).
    type: u8,
    /// Length of the name that follows, not counting the NUL.
    namlen: u16,
};

/// Directory entry types (NetBSD's DT_*).
pub const DT_UNKNOWN: u8 = 0;
pub const DT_FIFO: u8 = 1;
pub const DT_CHR: u8 = 2;
pub const DT_DIR: u8 = 4;
pub const DT_BLK: u8 = 6;
pub const DT_REG: u8 = 8;
pub const DT_LNK: u8 = 10;
pub const DT_SOCK: u8 = 12;

/// Smallest record size, header plus a one-byte name and its NUL, rounded up.
pub const DIRENT_BASE: u64 = 24;
