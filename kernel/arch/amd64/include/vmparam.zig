// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 virtual memory parameters.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/include/vmparam.h:
// the kernel virtual address layout constants. Only what early bring-up needs
// is defined; the full user/kernel split will grow as the VM system does.

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

/// Top of the initial user stack, in the lower (user) half.
pub const USER_STACK_TOP: u64 = 0x0000_0000_8000_0000;

/// Size of the initial user stack.
pub const USER_STACK_SIZE: u64 = 0x0000_0000_0080_0000;

/// Largest stack a process may ask for (FreeBSD's MAXSSIZ, 512 MiB on
/// amd64): setrlimit(RLIMIT_STACK) is clamped to it. libthr places the main
/// thread's guard page this far below the stack top, so it must be finite.
pub const MAXSSIZ: u64 = 512 * 1024 * 1024;
