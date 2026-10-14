// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// x87/SSE state of user processes.
//
// The Zig counterpart of FreeBSD's sys/amd64/amd64/fpu.c, reduced to FXSAVE:
// the kernel itself is built without floating point or SIMD, so the registers
// always hold the state of the process that last ran in user mode. The
// scheduler saves it when a process gives up the CPU and loads the next
// process's copy before it runs; signal frames and getcontext(2) carry it in
// the machine context.

/// An FXSAVE area (FreeBSD's struct savefpu without the XSAVE extension).
pub const Savefpu: type = extern struct {
    data: [512]u8 align(16),
};

/// The bits of MXCSR a program may set (DAZ left out: not every CPU has it).
const MXCSR_MASK: u32 = 0xffbf;

/// The state of a process that has not used the FPU yet: what FNINIT and the
/// MXCSR reset value give (all exceptions masked, round to nearest).
pub fn initial() Savefpu {
    var s: Savefpu = .{ .data = @splat(0) };
    // FCW 0x037f at offset 0, MXCSR 0x1f80 at offset 24.
    s.data[0] = 0x7f;
    s.data[1] = 0x03;
    s.data[24] = 0x80;
    s.data[25] = 0x1f;
    return s;
}

/// Save the live x87/SSE registers into `s`.
pub fn fpusave(s: *Savefpu) void {
    asm volatile ("fxsave64 (%[p])"
        :
        : [p] "r" (&s.data),
        : .{ .memory = true });
}

/// Load the x87/SSE registers from `s`.
pub fn fpurestore(s: *const Savefpu) void {
    asm volatile ("fxrstor64 (%[p])"
        :
        : [p] "r" (&s.data),
        : .{ .memory = true });
}

/// Make an image that came from user memory safe to load: reserved MXCSR
/// bits would raise #GP in the kernel.
pub fn sanitize(s: *Savefpu) void {
    var mxcsr: u32 = @as(u32, s.data[24]) | (@as(u32, s.data[25]) << 8) |
        (@as(u32, s.data[26]) << 16) | (@as(u32, s.data[27]) << 24);
    mxcsr &= MXCSR_MASK;
    s.data[24] = @truncate(mxcsr);
    s.data[25] = @truncate(mxcsr >> 8);
    s.data[26] = 0;
    s.data[27] = 0;
}
