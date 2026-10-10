// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// GDT layout and selectors for the x86 family.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/include/gdt.h (which in
// NetBSD declares the per-CPU GDT and TSS interfaces) combined with the GDT
// selector definitions. ZenBSD currently has a single flat GDT, so only the
// slot indices and the derived selectors are defined here.
//
// A future revision will add the per-CPU GDT and TSS, mirroring gdt_init_cpu()
// and tss_alloc() in NetBSD.

/// GDT slot indices.
pub const GDT_NULL: u16 = 0;
pub const GDT_KCODE: u16 = 1;
pub const GDT_KDATA: u16 = 2;
pub const GDT_UCODE: u16 = 3;
pub const GDT_UDATA: u16 = 4;

/// Derive a selector from a slot index and a requested privilege level.
pub fn selector(index: u16, rpl: u16) u16 {
    return (index << 3) | rpl;
}

/// Kernel code selector (ring 0).
pub const KCODE_SEL: u16 = selector(GDT_KCODE, 0);
/// Kernel data selector (ring 0).
pub const KDATA_SEL: u16 = selector(GDT_KDATA, 0);
/// User code selector (ring 3).
pub const UCODE_SEL: u16 = selector(GDT_UCODE, 3);
/// User data selector (ring 3).
pub const UDATA_SEL: u16 = selector(GDT_UDATA, 3);
