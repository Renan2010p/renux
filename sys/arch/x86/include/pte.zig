// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// x86-64 page table entry format.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/include/pte.h: the PTE
// bit definitions, the page-table level shifts and masks, and the physical
// frame masks for 4 KiB, 2 MiB and 1 GiB mappings.

// PTE permission and status bits.
pub const P: u64 = 1 << 0; // present
pub const RW: u64 = 1 << 1; // writable
pub const US: u64 = 1 << 2; // user accessible
pub const PWT: u64 = 1 << 3; // write-through
pub const PCD: u64 = 1 << 4; // cache disable
pub const A: u64 = 1 << 5; // accessed
pub const D: u64 = 1 << 6; // dirty
pub const PS: u64 = 1 << 7; // page size (large page)
pub const G: u64 = 1 << 8; // global
pub const NX: u64 = 1 << 63; // no execute

/// Physical address mask in a 4 KiB page table entry.
pub const FRAME_MASK: u64 = 0x000f_ffff_ffff_f000;

/// Physical address mask in a 2 MiB (large page) entry.
pub const FRAME_2M_MASK: u64 = 0x000f_ffff_ffe0_0000;

/// Physical address mask in a 1 GiB (large page) entry.
pub const FRAME_1G_MASK: u64 = 0x000f_ffff_c000_0000;

/// Shift for the level-1 (4 KiB) index.
pub const L1_SHIFT: u6 = 12;

/// Shift for the level-2 (2 MiB) index.
pub const L2_SHIFT: u6 = 21;

/// Shift for the level-3 (1 GiB) index.
pub const L3_SHIFT: u6 = 30;

/// Shift for the level-4 (512 GiB) index.
pub const L4_SHIFT: u6 = 39;
