// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine-dependent entry point and the transition into ring 3.
//
// _start is the kernel's first instruction, called by the bootloader. It does
// the bare machine setup (SSE, GDT/TSS, IDT) and then calls main(). enterUser()
// performs the reverse hand-off, returning control to a user process via iretq.

const cpu: type = @import("../../x86/include/cpufunc.zig");
const gdt_defs: type = @import("../../x86/include/gdt.zig");
const gdt: type = @import("gdt.zig");
const vector: type = @import("vector.zig");

extern fn main() void;

/// Kernel entry point.
export fn _start() callconv(.c) void {
    cpu.startup();
    gdt.init();
    vector.install();

    @call(.never_inline, main, .{});
}

/// Enter ring 3 at `entry` with the stack at `stack`, and never return.
///
/// The frame iretq consumes is, from the top: SS, RSP, RFLAGS, CS, RIP.
pub fn enterUser(entry: u64, stack: u64) noreturn {
    const ucode: u64 = gdt_defs.UCODE_SEL;
    const udata: u64 = gdt_defs.UDATA_SEL;

    asm volatile (
        \\ mov %[udata], %%ds
        \\ mov %[udata], %%es
        \\ pushq %[udata]
        \\ pushq %[stack]
        \\ pushq $0x202
        \\ pushq %[ucode]
        \\ pushq %[entry]
        \\ iretq
        :
        : [udata] "r" (udata),
          [stack] "r" (stack),
          [ucode] "r" (ucode),
          [entry] "r" (entry),
        : .{ .memory = true });
    unreachable;
}
