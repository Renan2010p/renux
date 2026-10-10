// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// ISA bus definitions.
//
// This is the Zig counterpart of NetBSD's sys/dev/isa/isareg.h, limited to the
// legacy I/O port addresses early bring-up needs.

/// Master 8259 PIC command/data ports.
pub const IO_PIC1: u16 = 0x20;

/// Slave 8259 PIC command/data ports.
pub const IO_PIC2: u16 = 0xa0;

/// 8253/8254 programmable interval timer base port.
pub const IO_TIMER1: u16 = 0x40;

/// Base I/O port of the CMOS/RTC index and data registers.
pub const IO_RTC: u16 = 0x70;
