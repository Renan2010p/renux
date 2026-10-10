// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// 8259 interrupt controller definitions.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/include/i8259.h: the
// initialisation and operation command words, and the vector offsets the PICs
// are remapped to.

// Initialisation command word 1.
pub const ICW1_ICW4: u8 = 0x01; // ICW4 is present
pub const ICW1_SINGLE: u8 = 0x02; // single master, no cascade
pub const ICW1_INIT: u8 = 0x10; // begin initialisation

// Initialisation command word 4 (8086/88 mode).
pub const ICW4_8086: u8 = 0x01;

// Operation command word 2: end of interrupt.
pub const OCW2_EOI: u8 = 0x20;

/// First vector the master PIC is remapped to (IRQ0).
pub const PIC_MASTER_OFFSET: u8 = 0x20;

/// First vector the slave PIC is remapped to (IRQ8).
pub const PIC_SLAVE_OFFSET: u8 = 0x28;

/// Master IRQ line the slave PIC is cascaded through.
pub const PIC_CASCADE_IRQ: u3 = 2;
