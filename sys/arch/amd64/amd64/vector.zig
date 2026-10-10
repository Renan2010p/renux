// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// amd64 interrupt vector stubs.
//
// This plays the role of NetBSD's sys/arch/amd64/amd64/vector.S: for every one
// of the 256 architectural vectors it produces a tiny entry stub that pushes
// the vector number (and a dummy error code when the CPU does not push one) and
// jumps to the common entry. These are built as Zig naked functions rather than
// assembly, keeping the kernel free of hand-written assembler files.

const idt: type = @import("../../x86/x86/idt.zig");
const segments: type = @import("../../x86/include/segments.zig");

/// Build the entry stub for one vector.
///
/// Vectors 8, 10-14, 17, 21, 29 and 30 push an error code; the others do not,
/// so a dummy 0 is pushed to give every trap the same frame layout.
fn Stub(comptime vector: u8, comptime pushes_error: bool) type {
    return struct {
        fn entry() callconv(.naked) void {
            if (pushes_error) {
                asm volatile (
                    \\ pushq %[vec]
                    \\ jmp trap_common
                    :
                    : [vec] "i" (vector),
                );
            } else {
                asm volatile (
                    \\ pushq $0
                    \\ pushq %[vec]
                    \\ jmp trap_common
                    :
                    : [vec] "i" (vector),
                );
            }
        }
    };
}

/// Whether the CPU pushes an error code for `vector`.
fn pushesErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Install all 256 gates (as interrupt gates, DPL 0) and load the IDT.
pub fn install() void {
    inline for (0..idt.IDT_ENTRIES) |i| {
        const vector: u8 = i;
        const handler: u64 = @intFromPtr(&Stub(vector, pushesErrorCode(vector)).entry);
        idt.setgate(vector, handler, 0, segments.SDT_SYS386IGT, 0);
    }
    idt.load();
}
