// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine-independent page constants.
//
// This is the Zig counterpart of the page-size part of NetBSD's
// sys/sys/param.h. NetBSD sources these from <machine/param.h>; Renux fixes
// them here because every supported port so far uses 4 KiB pages.

/// log2 of the page size.
pub const PAGE_SHIFT: u6 = 12;

/// Page size in bytes.
pub const PAGE_SIZE: u64 = 4096;

/// Mask selecting the offset within a page.
pub const PAGE_MASK: u64 = PAGE_SIZE - 1;

/// Pages in each process's kernel stack (FreeBSD's KSTACK_PAGES on amd64).
/// System calls that reach the console (tty, terminal emulator, rasops) run
/// deep, especially in a debug kernel; one page overflowed into whatever page
/// followed it.
pub const KSTACK_PAGES: u64 = 4;

/// Written at the lowest word of every kernel stack; a changed value means
/// the stack overflowed (checked at each context switch).
pub const KSTACK_CANARY: u64 = 0x5245_4e55_5853_544b; // "RENUXSTK"

/// Maximum length of a pathname, NUL not included (NetBSD's MAXPATHLEN).
pub const MAXPATHLEN: usize = 1024;

/// Base of the region anonymous mmap() allocates from.
pub const USER_MMAP_BASE: u64 = 0x0000_0000_4000_0000;

/// Round `value` up to the next multiple of `alignment` (a power of two).
pub fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}
