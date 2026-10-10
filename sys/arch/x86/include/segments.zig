// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// x86 segment and gate descriptor formats.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/include/segments.h
// (and the equivalent i386 header). NetBSD keeps one copy per x86 arch because
// the descriptors are almost, but not entirely, identical; ZenBSD consolidates
// them in the shared x86 tree.

/// Segment descriptor type and access fields (the SDT_* values in NetBSD).
pub const SDT_SYSNULL: u8 = 0x00; // system: null
pub const SDT_SYS386TSS: u8 = 0x09; // system: 386 available TSS
pub const SDT_SYS386BSY: u8 = 0x0b; // system: 386 busy TSS
pub const SDT_SYS386IGT: u8 = 0x0e; // system: 386 interrupt gate
pub const SDT_SYS386TGT: u8 = 0x0f; // system: 386 trap gate

pub const SDT_MEMRO: u8 = 0x10; // memory: read-only
pub const SDT_MEMRW: u8 = 0x12; // memory: read/write
pub const SDT_MEME: u8 = 0x18; // memory: execute-only
pub const SDT_MEMER: u8 = 0x1a; // memory: execute/read

/// Segment descriptor, as laid out by the CPU (8 bytes).
pub const SegmentDescriptor: type = extern struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8, // limit[19:16] in the low nibble, flags in the high nibble
    base_high: u8,
};

/// IDT gate descriptor, as laid out by the CPU (16 bytes, long mode).
pub const GateDescriptor: type = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    reserved: u5,
    type: u4, // one of SDT_*
    s: u1, // 0 selects a system descriptor
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved2: u32,
};

/// Build an IDT gate descriptor pointing `handler` at the given `selector`.
pub fn makeGate(handler: u64, selector: u16, ist: u3, gate_type: u4, dpl: u2) GateDescriptor {
    return .{
        .offset_low = @truncate(handler),
        .selector = selector,
        .ist = ist,
        .reserved = 0,
        .type = gate_type,
        .s = 0,
        .dpl = dpl,
        .present = 1,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved2 = 0,
    };
}
