// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// User context.
//
// The Zig counterpart of FreeBSD's sys/sys/_ucontext.h: the saved signal mask
// and machine context that signal handlers receive and that getcontext(2),
// setcontext(2) and sigreturn(2) exchange with the kernel.

const arch: type = @import("../arch/arch.zig");

/// sigaltstack(2) description (stack_t).
pub const Stack: type = extern struct {
    ss_sp: u64,
    ss_size: u64,
    ss_flags: i32,
};

/// ucontext_t.
pub const Ucontext: type = extern struct {
    /// Signals blocked in the context (a sigset_t).
    uc_sigmask: [4]u32,
    uc_mcontext: arch.ucontext.Mcontext,
    uc_link: u64,
    uc_stack: Stack,
    uc_flags: i32,
    __spare__: [4]i32,
};

/// The low 64 signals of a sigset_t (Renux has 32).
pub fn maskOf(set: [4]u32) u64 {
    return @as(u64, set[0]) | (@as(u64, set[1]) << 32);
}

/// A sigset_t holding `mask`.
pub fn setOf(mask: u64) [4]u32 {
    return .{ @truncate(mask), @truncate(mask >> 32), 0, 0 };
}
