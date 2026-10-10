// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent GDT setup for the amd64 port.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/amd64/gdt.c. It
// builds the flat GDT used during early bring-up (null, kernel code/data, user
// code/data), loads it with lgdt, and reloads the segment registers. The TSS
// and per-CPU GDTs that NetBSD allocates here are deferred until user mode and
// interrupt stacks exist.

const segments: type = @import("../../x86/include/segments.zig");
const gdt_defs: type = @import("../../x86/include/gdt.zig");

const GDT_ENTRIES: usize = 5;

// Segment descriptor flag nibbles (the high nibble of the granularity byte).
const FLAGS_CODE64: u8 = 0xa; // G=1 (4K), L=1 (long mode), D/B=0
const FLAGS_DATA: u8 = 0xc; // G=1 (4K), D/B=1

// Access bytes: P=1, DPL, S=1, type.
const ACCESS_KCODE: u8 = 0x9a; // ring 0, execute/read
const ACCESS_KDATA: u8 = 0x92; // ring 0, read/write
const ACCESS_UCODE: u8 = 0xfa; // ring 3, execute/read
const ACCESS_UDATA: u8 = 0xf2; // ring 3, read/write

/// The GDT itself.
var gdt: [GDT_ENTRIES]segments.SegmentDescriptor = undefined;

const Gdtr: type = packed struct {
    limit: u16,
    base: u64,
};

var gdtr: Gdtr = undefined;

/// Encode a present, 4 KiB-granular flat segment descriptor.
fn segment(access: u8, flags: u8) segments.SegmentDescriptor {
    return .{
        .limit_low = 0xffff,
        .base_low = 0,
        .base_mid = 0,
        .access = access,
        .granularity = (flags << 4) | 0x0f,
        .base_high = 0,
    };
}

/// Reload the data segment registers and the code segment register.
///
/// The code selector cannot be loaded with a plain mov; it needs a far return.
fn reloadSegments() void {
    asm volatile (
        \\ mov %[kdata], %%ds
        \\ mov %[kdata], %%es
        \\ mov %[kdata], %%ss
        \\ xor %%eax, %%eax
        \\ mov %%eax, %%fs
        \\ mov %%eax, %%gs
        \\ pushq %[kcode]
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        :
        : [kdata] "r" (@as(u64, gdt_defs.KDATA_SEL)),
          [kcode] "r" (@as(u64, gdt_defs.KCODE_SEL)),
        : .{ .memory = true });
}

/// Build and install the early GDT.
pub fn init() void {
    gdt[gdt_defs.GDT_NULL] = .{
        .limit_low = 0,
        .base_low = 0,
        .base_mid = 0,
        .access = 0,
        .granularity = 0,
        .base_high = 0,
    };
    gdt[gdt_defs.GDT_KCODE] = segment(ACCESS_KCODE, FLAGS_CODE64);
    gdt[gdt_defs.GDT_KDATA] = segment(ACCESS_KDATA, FLAGS_DATA);
    gdt[gdt_defs.GDT_UCODE] = segment(ACCESS_UCODE, FLAGS_CODE64);
    gdt[gdt_defs.GDT_UDATA] = segment(ACCESS_UDATA, FLAGS_DATA);

    gdtr = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&gdtr),
        : .{ .memory = true });

    reloadSegments();
}
