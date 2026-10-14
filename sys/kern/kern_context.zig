// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// User contexts.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_context.c: getcontext(2),
// setcontext(2) and swapcontext(2) move a ucontext_t (signal mask plus the
// machine context the port fills in) between a program and its registers.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const signal: type = @import("../sys/signal.zig");
const ucontext: type = @import("../sys/ucontext.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");

/// User addresses end here (exclusive).
const VM_MAXUSER_ADDRESS: u64 = 0x0000_8000_0000_0000;

fn userUcontext(addr: u64) ?*align(1) ucontext.Ucontext {
    if (addr == 0 or addr >= VM_MAXUSER_ADDRESS - @sizeOf(ucontext.Ucontext)) return null;
    return @ptrFromInt(addr);
}

/// Store the caller's context, as it will be when the call returns 0.
fn getContext(addr: u64) u64 {
    const frame = arch.trap.currentFrame() orelse return sys.signed(-errno.EINVAL);
    const uc = userUcontext(addr) orelse return sys.signed(-errno.EFAULT);
    const raw: [*]u8 = @ptrCast(uc);
    @memset(raw[0..@sizeOf(ucontext.Ucontext)], 0);
    uc.uc_sigmask = ucontext.setOf(kern_proc.current.sig_mask);
    arch.exec_machdep.getMcontext(frame, &uc.uc_mcontext, true);
    return 0;
}

/// Resume the context at `addr`.
fn setContext(addr: u64) u64 {
    const frame = arch.trap.currentFrame() orelse return sys.signed(-errno.EINVAL);
    const uc = userUcontext(addr) orelse return sys.signed(-errno.EFAULT);
    if (!arch.exec_machdep.setMcontext(frame, &uc.uc_mcontext)) return sys.signed(-errno.EINVAL);
    kern_proc.current.sig_mask = ucontext.maskOf(uc.uc_sigmask) & ~signal.CANTMASK;
    return sys.signed(-errno.EJUSTRETURN);
}

/// getcontext(2): `getcontext(ucp)`.
pub fn sysGetcontext(args: [sys.MAXARGS]u64) u64 {
    return getContext(args[0]);
}

/// setcontext(2): `setcontext(ucp)`.
pub fn sysSetcontext(args: [sys.MAXARGS]u64) u64 {
    return setContext(args[0]);
}

/// swapcontext(2): `swapcontext(oucp, ucp)`, save the caller's context in
/// `oucp` and resume `ucp`.
pub fn sysSwapcontext(args: [sys.MAXARGS]u64) u64 {
    const r: u64 = getContext(args[0]);
    if (r != 0) return r;
    return setContext(args[1]);
}
