// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Interrupt vector definitions for the x86 family.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/include/intrdefs.h,
// limited to the legacy PIC vector range used during bring-up.

/// First vector the PICs are remapped to; IRQ n is delivered as 0x20 + n.
pub const IRQ_VECTOR_BASE: u64 = 0x20;

/// Number of legacy PIC interrupt lines.
pub const NUM_IRQS: u8 = 16;

/// Vector for IRQ `irq` (0..15).
pub fn irqVector(irq: u3) u64 {
    return IRQ_VECTOR_BASE + irq;
}

/// True when `vector` is in the legacy PIC range.
pub fn isPicVector(vector: u64) bool {
    return vector >= IRQ_VECTOR_BASE and vector < IRQ_VECTOR_BASE + NUM_IRQS;
}
