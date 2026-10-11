// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// 8253/8254 programmable interval timer definitions.
//
// This is the Zig counterpart of NetBSD's sys/dev/ic/i8253reg.h: the counter
// and control-word bit fields used to program timer channel 0 as the system
// tick.

/// Channel 0 data port offset (system timer).
pub const TIMER_CNTR0: u16 = 0;

/// Channel 1 data port offset.
pub const TIMER_CNTR1: u16 = 1;

/// Channel 2 data port offset.
pub const TIMER_CNTR2: u16 = 2;

/// Mode/command register offset.
pub const TIMER_MODE: u16 = 3;

// Control-word fields.
pub const TIMER_SEL0: u8 = 0x00; // select channel 0
pub const TIMER_SEL1: u8 = 0x40;
pub const TIMER_SEL2: u8 = 0x80;
pub const TIMER_LSB: u8 = 0x10; // access the low byte only
pub const TIMER_MSB: u8 = 0x20; // access the high byte only
pub const TIMER_LSB_MSB: u8 = 0x30; // access low then high byte
pub const TIMER_RATEGEN: u8 = 0x04; // mode 2: rate generator
pub const TIMER_MODE_SQW: u8 = 0x06; // mode 3: square wave

/// Input clock of the PIT, in Hz.
pub const TIMER_FREQ: u32 = 1_193_182;
