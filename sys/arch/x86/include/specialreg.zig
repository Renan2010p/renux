// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// x86 special registers and model-specific registers.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/include/specialreg.h,
// limited to the control-register bits and MSRs early bring-up needs.

// Control register 0 bits.
pub const CR0_PE: u64 = 0x0000_0001; // protected mode enable
pub const CR0_MP: u64 = 0x0000_0002; // monitor coprocessor
pub const CR0_EM: u64 = 0x0000_0004; // emulate coprocessor
pub const CR0_TS: u64 = 0x0000_0008; // task switched
pub const CR0_WP: u64 = 0x0001_0000; // write protect
pub const CR0_PG: u64 = 0x8000_0000; // paging enable

// Control register 4 bits.
pub const CR4_PAE: u64 = 0x0000_0020; // physical address extension
pub const CR4_OSFXSR: u64 = 0x0000_0200; // FXSAVE/FXRSTOR and SSE
pub const CR4_OSXMMEXCPT: u64 = 0x0000_0400; // unmasked SIMD exceptions

// Extended Feature Enable Register (IA32_EFER).
pub const MSR_EFER: u32 = 0xc000_0080;
pub const EFER_SCE: u64 = 1 << 0; // syscall/sysret enable
pub const EFER_LME: u64 = 1 << 8; // long mode enable
pub const EFER_LMA: u64 = 1 << 10; // long mode active
pub const EFER_NXE: u64 = 1 << 11; // no-execute enable

// syscall/sysret configuration MSRs.
pub const MSR_STAR: u32 = 0xc000_0081;
pub const MSR_LSTAR: u32 = 0xc000_0082;
pub const MSR_SFMASK: u32 = 0xc000_0084;

// Local APIC base MSR.
pub const MSR_APICBASE: u32 = 0x0000_001b;
pub const APICBASE_ENABLE: u64 = 1 << 11;
pub const APICBASE_BSP: u64 = 1 << 8;
