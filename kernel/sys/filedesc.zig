// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The per-process file descriptor table.
//
// The Zig counterpart of FreeBSD's sys/sys/filedesc.h. A descriptor is an
// index into the table; each entry holds the open file (struct file) and the
// descriptor's flags. As in FreeBSD, every process starts with room for
// NDFILE descriptors inside its own process structure, and the table grows
// (doubling) when a process opens more, up to the process's limit
// (kern_descrip.getmaxfd: RLIMIT_NOFILE, capped by kern.maxfilesperproc).
//
// The operations on the table are in kernel/core/kern_descrip.zig.

const file: type = @import("file.zig");

/// Descriptors every process has room for before its table first grows
/// (FreeBSD's NDFILE).
pub const NDFILE: usize = 20;

/// One descriptor (FreeBSD's struct filedescent).
pub const Entry: type = struct {
    /// The open file, or null for a free descriptor.
    file: ?*file.File = null,
    /// Close the descriptor at execve(2) (FD_CLOEXEC; FreeBSD's UF_EXCLOSE).
    cloexec: bool = false,
};

/// The table (FreeBSD's struct filedesc).
pub const FileDesc: type = struct {
    /// The first NDFILE entries, inside the process structure (FreeBSD's
    /// fdp0's fd_dfiles).
    initial: [NDFILE]Entry = @splat(.{}),
    /// The grown table, when the process has outgrown `initial`; allocated
    /// by kern_descrip and holding a copy of the initial entries.
    grown: ?[]Entry = null,

    /// All the entries: their count is the table's size (FreeBSD's
    /// fd_nfiles).
    pub fn entries(fdp: *FileDesc) []Entry {
        return fdp.grown orelse &fdp.initial;
    }

    /// The number of descriptors the table has room for.
    pub fn size(fdp: *FileDesc) usize {
        return fdp.entries().len;
    }

    /// The entry of descriptor `fd`, or null when `fd` is beyond the table.
    pub fn entry(fdp: *FileDesc, fd: usize) ?*Entry {
        const all: []Entry = fdp.entries();
        if (fd >= all.len) return null;
        return &all[fd];
    }
};
