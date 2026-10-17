// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 virtual memory parameters.
//
// The Zig counterpart of FreeBSD's sys/amd64/include/vmparam.h: the layout of
// the address space. The user half is FreeBSD/amd64's: 128 TiB, with the
// main stack at the top and mmap(2) room below it.

const param: type = @import("../../../sys/param.zig");

/// log2 of the page size (re-exported so MD code has one obvious place).
pub const PAGE_SHIFT: u6 = param.PAGE_SHIFT;

/// Page size in bytes.
pub const PAGE_SIZE: u64 = param.PAGE_SIZE;

/// Scratch kernel virtual address used to map arbitrary physical pages during
/// bring-up. It falls in PML4 slot 510, which the bootloader leaves unused, so
/// installing a mapping there creates fresh page tables rather than having to
/// split an existing large page.
pub const KERNEL_SCRATCH_BASE: u64 = 0xffffff0000000000;

/// One past the highest user address (FreeBSD's VM_MAXUSER_ADDRESS).
pub const VM_MAXUSER_ADDRESS: u64 = 0x0000_7fff_ffff_f000;

/// Top of the main thread's stack (FreeBSD's USRSTACK: one page below the
/// top, where FreeBSD keeps its shared page).
pub const USER_STACK_TOP: u64 = VM_MAXUSER_ADDRESS - PAGE_SIZE;

/// Address space reserved for the main stack below USER_STACK_TOP, filled
/// on demand like any anonymous memory (the default RLIMIT_STACK).
pub const USER_STACK_SIZE: u64 = 64 * 1024 * 1024;

/// Largest stack a process may ask for (FreeBSD's MAXSSIZ, 512 MiB on
/// amd64): setrlimit(RLIMIT_STACK) is clamped to it. libthr places the main
/// thread's guard page this far below the stack top, so it must be finite.
pub const MAXSSIZ: u64 = 512 * 1024 * 1024;
