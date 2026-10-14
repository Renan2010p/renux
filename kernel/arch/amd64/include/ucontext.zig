// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine context.
//
// The Zig counterpart of FreeBSD's sys/amd64/include/ucontext.h: the register
// state a signal frame, getcontext(2) and sigreturn(2) carry, laid out
// exactly as FreeBSD/amd64 programs (and libthr's signal wrapper) expect.

/// mc_flags: the segment registers and the fs/gs bases are valid.
pub const _MC_HASSEGS: u32 = 0x1;
pub const _MC_HASBASES: u32 = 0x2;

/// mc_fpformat and mc_ownedfp values.
pub const _MC_FPFMT_NODEV: i64 = 0x10000;
pub const _MC_FPFMT_XMM: i64 = 0x10002;
pub const _MC_FPOWNED_NONE: i64 = 0x20000;
pub const _MC_FPOWNED_FPU: i64 = 0x20001;

/// struct __mcontext (800 bytes).
pub const Mcontext: type = extern struct {
    mc_onstack: u64,
    mc_rdi: u64,
    mc_rsi: u64,
    mc_rdx: u64,
    mc_rcx: u64,
    mc_r8: u64,
    mc_r9: u64,
    mc_rax: u64,
    mc_rbx: u64,
    mc_rbp: u64,
    mc_r10: u64,
    mc_r11: u64,
    mc_r12: u64,
    mc_r13: u64,
    mc_r14: u64,
    mc_r15: u64,
    mc_trapno: u32,
    mc_fs: u16,
    mc_gs: u16,
    mc_addr: u64,
    mc_flags: u32,
    mc_es: u16,
    mc_ds: u16,
    mc_err: u64,
    mc_rip: u64,
    mc_cs: u64,
    mc_rflags: u64,
    mc_rsp: u64,
    mc_ss: u64,
    mc_len: i64,
    mc_fpformat: i64,
    mc_ownedfp: i64,
    /// The FXSAVE image of the x87/SSE state.
    mc_fpstate: [512]u8 align(16),
    mc_fsbase: u64,
    mc_gsbase: u64,
    mc_xfpustate: u64,
    mc_xfpustate_len: u64,
    mc_spare: [4]i64,
};

comptime {
    if (@sizeOf(Mcontext) != 800) @compileError("ucontext: struct __mcontext must be 800 bytes");
}
