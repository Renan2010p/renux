// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 trap frame layout.
//
// This is the Zig counterpart of the trap frame in NetBSD's
// sys/arch/amd64/include/trap.h. It describes how the vector stubs and the
// common trap entry leave the machine state on the stack, so the Zig trap
// dispatcher can read it.
//
// Stack, from the lowest address (what rsp points at when the dispatcher runs)
// to the highest:
//
//   pushed by the common entry: r15 .. rax   (15 general registers)
//   pushed by the vector stub:  vector, error
//   pushed by the CPU:          rip, cs, rflags, rsp, ss

pub const TrapFrame: type = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,

    /// Interrupt vector number.
    vector: u64,
    /// Error code pushed by the CPU (or a dummy 0).
    error_code: u64,

    /// Instruction pointer at the time of the trap.
    rip: u64,
    /// Code segment selector.
    cs: u64,
    /// RFLAGS at the time of the trap.
    rflags: u64,
    /// Stack pointer at the time of the trap.
    rsp: u64,
    /// Stack segment selector.
    ss: u64,
};

/// Architectural exception vectors (the T_* values in NetBSD's trap.h).
pub const T_DIVIDE: u64 = 0;
pub const T_DEBUG: u64 = 1;
pub const T_NMI: u64 = 2;
pub const T_BREAKPOINT: u64 = 3;
pub const T_OVERFLOW: u64 = 4;
pub const T_BOUND: u64 = 5;
pub const T_ILL: u64 = 6;
pub const T_DNA: u64 = 7;
pub const T_DOUBLE: u64 = 8;
pub const T_SEGNP: u64 = 11;
pub const T_STACK: u64 = 12;
pub const T_GP: u64 = 13;
pub const T_PAGE: u64 = 14;
pub const T_FPU: u64 = 16;
pub const T_ALIGN: u64 = 17;
