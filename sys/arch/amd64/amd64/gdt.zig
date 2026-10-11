// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent GDT setup for the amd64 port.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/amd64/gdt.c. It builds
// the flat GDT (null, kernel code/data, user code/data) plus a 64-bit Task State
// Segment, loads it with lgdt, reloads the segment registers and loads the TSS
// with ltr. The TSS supplies the kernel stack pointer (rsp0) the CPU switches to
// when control transfers from ring 3 to ring 0.

const gdt_defs: type = @import("../../x86/include/gdt.zig");

/// Number of GDT slots.
const GDT_SLOTS: usize = gdt_defs.GDT_SLOTS;

// Segment descriptor flag nibbles (high nibble of the granularity byte).
const FLAGS_CODE64: u8 = 0xa; // G=1 (4K), L=1 (long mode), D/B=0
const FLAGS_DATA: u8 = 0xc; // G=1 (4K), D/B=1

// Access bytes: P=1, DPL, S=1, type.
const ACCESS_KCODE: u8 = 0x9a; // ring 0, execute/read
const ACCESS_KDATA: u8 = 0x92; // ring 0, read/write
const ACCESS_UCODE: u8 = 0xfa; // ring 3, execute/read
const ACCESS_UDATA: u8 = 0xf2; // ring 3, read/write

// Access byte for an available 64-bit Task State Segment.
const ACCESS_TSS: u8 = 0x89;

/// Size of the 64-bit TSS.
const TSS_SIZE: usize = 104;

/// Offset of rsp0 within the TSS. It follows a 4-byte reserved field, so it is
/// not naturally 8-byte aligned; the CPU reads it there regardless.
const TSS_RSP0_OFFSET: usize = 4;

/// Offset of the I/O permission bitmap base within the TSS.
const TSS_IOMAP_OFFSET: usize = 102;

/// The TSS is kept as raw bytes because rsp0 sits at offset 4: a normal struct
/// would insert padding before the 64-bit field and move it to offset 8, which
/// is not where the CPU looks.
var tss: [TSS_SIZE]u8 = undefined;

/// Write a 64-bit value into the TSS at `offset`.
fn tssPutU64(offset: usize, value: u64) void {
    const p: *align(1) u64 = @ptrFromInt(@intFromPtr(&tss) + offset);
    p.* = value;
}

/// Write a 16-bit value into the TSS at `offset`.
fn tssPutU16(offset: usize, value: u16) void {
    const p: *align(1) u16 = @ptrFromInt(@intFromPtr(&tss) + offset);
    p.* = value;
}

/// The GDT itself.
var gdt: [GDT_SLOTS]u64 = .{ 0, 0, 0, 0, 0, 0, 0 };

const Gdtr: type = packed struct {
    limit: u16,
    base: u64,
};

var gdtr: Gdtr = .{ .limit = 0, .base = 0 };

/// Encode a present, 4 KiB-granular, base-0 flat segment descriptor.
fn encodeSegment(access: u8, flags: u8) u64 {
    const granularity: u64 = (@as(u64, flags) << 4) | 0x0f;
    return 0xffff | (@as(u64, access) << 40) | (granularity << 48);
}

/// Encode a 64-bit TSS descriptor (two 8-byte entries).
fn encodeTss(base: u64, limit: u16) [2]u64 {
    const low: u64 = @as(u64, limit & 0xffff) |
        ((base & 0x00ff_ffff) << 16) |
        (@as(u64, ACCESS_TSS) << 40) |
        (((@as(u64, limit) >> 16) & 0x0f) << 48) |
        (((base >> 24) & 0xff) << 56);
    const high: u64 = base >> 32;
    return .{ low, high };
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

/// Build and install the GDT and TSS.
pub fn init() void {
    // Clear the TSS and mark the I/O bitmap as absent.
    var i: usize = 0;
    while (i < TSS_SIZE) : (i += 1) {
        tss[i] = 0;
    }
    tssPutU16(TSS_IOMAP_OFFSET, TSS_SIZE);

    gdt[gdt_defs.GDT_NULL] = 0;
    gdt[gdt_defs.GDT_KCODE] = encodeSegment(ACCESS_KCODE, FLAGS_CODE64);
    gdt[gdt_defs.GDT_KDATA] = encodeSegment(ACCESS_KDATA, FLAGS_DATA);
    gdt[gdt_defs.GDT_UCODE] = encodeSegment(ACCESS_UCODE, FLAGS_CODE64);
    gdt[gdt_defs.GDT_UDATA] = encodeSegment(ACCESS_UDATA, FLAGS_DATA);

    const tss_desc: [2]u64 = encodeTss(@intFromPtr(&tss), TSS_SIZE - 1);
    gdt[gdt_defs.GDT_TSS] = tss_desc[0];
    gdt[gdt_defs.GDT_TSS + 1] = tss_desc[1];

    gdtr = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&gdtr),
        : .{ .memory = true });

    reloadSegments();

    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (@as(u16, gdt_defs.TSS_SEL)),
    );
}

/// Set the ring 0 stack used when control transfers from ring 3.
pub fn setKernelStack(sp: u64) void {
    tssPutU64(TSS_RSP0_OFFSET, sp);
}
