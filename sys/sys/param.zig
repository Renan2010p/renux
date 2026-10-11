// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-independent page constants.
//
// This is the Zig counterpart of the page-size part of NetBSD's
// sys/sys/param.h. NetBSD sources these from <machine/param.h>; ZenBSD fixes
// them here because every supported port so far uses 4 KiB pages.

/// log2 of the page size.
pub const PAGE_SHIFT: u6 = 12;

/// Page size in bytes.
pub const PAGE_SIZE: u64 = 4096;

/// Mask selecting the offset within a page.
pub const PAGE_MASK: u64 = PAGE_SIZE - 1;

/// Maximum length of a pathname, NUL not included (NetBSD's MAXPATHLEN).
pub const MAXPATHLEN: usize = 1024;

/// Base of the region anonymous mmap() allocates from.
pub const USER_MMAP_BASE: u64 = 0x0000_0000_4000_0000;

/// Round `value` up to the next multiple of `alignment` (a power of two).
pub fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}
