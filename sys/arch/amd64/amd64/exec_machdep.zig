// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Signal frames and machine contexts.
//
// The Zig counterpart of the signal half of FreeBSD's
// sys/amd64/amd64/exec_machdep.c (sendsig, sys_sigreturn, get_mcontext,
// set_mcontext) and of sys/amd64/amd64/sigtramp.S. A caught signal gets a
// struct sigframe on the user stack, below the red zone: the handler's
// address, a ucontext_t with the interrupted registers, FPU state and signal
// mask, and a siginfo_t. The process resumes in the signal trampoline, which
// calls the handler as handler(sig, &siginfo, &ucontext) and then hands the
// ucontext to sigreturn(2), which restores it.

const trapframe: type = @import("../include/trap.zig");
const ucontext_md: type = @import("../include/ucontext.zig");
const gdt_defs: type = @import("../../x86/include/gdt.zig");
const cpufunc: type = @import("../../x86/include/cpufunc.zig");
const fpu: type = @import("fpu.zig");
const sys: type = @import("../../../sys/syscall.zig");
const errno: type = @import("../../../sys/errno.zig");
const signal: type = @import("../../../sys/signal.zig");
const ucontext: type = @import("../../../sys/ucontext.zig");
const kern_proc: type = @import("../../../kern/kern_proc.zig");
const kern_exec: type = @import("../../../kern/kern_exec.zig");
const trap: type = @import("trap.zig");

const TrapFrame: type = trapframe.TrapFrame;
const Mcontext: type = ucontext_md.Mcontext;

/// The amd64 ABI lets leaf functions use 128 bytes below the stack pointer;
/// a signal frame must not overwrite them.
const REDZONE: u64 = 128;

/// rflags bits a user context may change (FreeBSD's PSL_USERCHANGE: the
/// arithmetic flags, TF, DF, OF, NT, AC and ID).
const PSL_USERCHANGE: u64 = 0x244dd5;
const PSL_T: u64 = 0x100;
const PSL_D: u64 = 0x400;
const PSL_C: u64 = 0x1;

/// End of the user address space (exclusive).
const VM_MAXUSER_ADDRESS: u64 = 0x0000_8000_0000_0000;

/// struct sigframe: what the trampoline finds at the stack pointer.
pub const Sigframe: type = extern struct {
    /// The handler the trampoline calls (SIGF_HANDLER, offset 0).
    sf_ahu: u64,
    _pad: u64,
    /// The interrupted context (SIGF_UC, offset 16).
    sf_uc: ucontext.Ucontext,
    sf_si: signal.Siginfo,
};

comptime {
    if (@offsetOf(Sigframe, "sf_uc") != 16) @compileError("exec_machdep: SIGF_UC must be 16");
}

/// The signal trampoline (FreeBSD's sigcode), copied to the page the
/// process returns to from sendsig():
///   call *SIGF_HANDLER(%rsp)
///   lea  SIGF_UC(%rsp), %rdi
///   pushq $0                      (fake return address)
///   movl $SYS_sigreturn, %eax
///   syscall
///   0: hlt; jmp 0b
pub const sigcode = [_]u8{
    0xff, 0x14, 0x24,
    0x48, 0x8d, 0x7c, 0x24, 0x10,
    0x6a, 0x00,
    0xb8, 0xa1, 0x01, 0x00, 0x00,
    0x0f, 0x05,
    0xf4,
    0xeb, 0xfd,
};

/// Fill `mc` with the context `frame` returns to. With `clear_ret` the
/// context reads as a system call that returned 0 (getcontext(2)).
pub fn getMcontext(frame: *const TrapFrame, mc: *align(1) Mcontext, clear_ret: bool) void {
    const p = kern_proc.current;
    const raw: [*]u8 = @ptrCast(mc);
    @memset(raw[0..@sizeOf(Mcontext)], 0);
    mc.mc_rdi = frame.rdi;
    mc.mc_rsi = frame.rsi;
    mc.mc_rdx = frame.rdx;
    mc.mc_rcx = frame.rcx;
    mc.mc_r8 = frame.r8;
    mc.mc_r9 = frame.r9;
    mc.mc_rax = frame.rax;
    mc.mc_rbx = frame.rbx;
    mc.mc_rbp = frame.rbp;
    mc.mc_r10 = frame.r10;
    mc.mc_r11 = frame.r11;
    mc.mc_r12 = frame.r12;
    mc.mc_r13 = frame.r13;
    mc.mc_r14 = frame.r14;
    mc.mc_r15 = frame.r15;
    mc.mc_trapno = @truncate(frame.vector);
    mc.mc_err = frame.error_code;
    mc.mc_rip = frame.rip;
    mc.mc_cs = frame.cs;
    mc.mc_rflags = frame.rflags;
    mc.mc_rsp = frame.rsp;
    mc.mc_ss = frame.ss;
    if (clear_ret) {
        mc.mc_rax = 0;
        mc.mc_rdx = 0;
        mc.mc_rflags &= ~PSL_C;
    }
    mc.mc_flags = ucontext_md._MC_HASBASES;
    mc.mc_fsbase = p.fsbase;
    mc.mc_len = @sizeOf(Mcontext);

    // The registers hold this process's FPU state (the kernel never uses
    // them); FXSAVE needs an aligned buffer, so go through one.
    var s: fpu.Savefpu = undefined;
    fpu.fpusave(&s);
    @memcpy(raw[@offsetOf(Mcontext, "mc_fpstate")..][0..512], &s.data);
    mc.mc_fpformat = ucontext_md._MC_FPFMT_XMM;
    mc.mc_ownedfp = ucontext_md._MC_FPOWNED_FPU;
}

/// Make `frame` return to the context in `mc`. The selectors stay the user
/// ones and only the user-changeable rflags bits are taken.
pub fn setMcontext(frame: *TrapFrame, mc: *align(1) const Mcontext) bool {
    if (mc.mc_len != @sizeOf(Mcontext)) return false;
    if ((mc.mc_flags & ucontext_md._MC_HASBASES) != 0 and mc.mc_fsbase >= VM_MAXUSER_ADDRESS) return false;
    if (mc.mc_rip >= VM_MAXUSER_ADDRESS) return false;

    const p = kern_proc.current;
    frame.rdi = mc.mc_rdi;
    frame.rsi = mc.mc_rsi;
    frame.rdx = mc.mc_rdx;
    frame.rcx = mc.mc_rcx;
    frame.r8 = mc.mc_r8;
    frame.r9 = mc.mc_r9;
    frame.rax = mc.mc_rax;
    frame.rbx = mc.mc_rbx;
    frame.rbp = mc.mc_rbp;
    frame.r10 = mc.mc_r10;
    frame.r11 = mc.mc_r11;
    frame.r12 = mc.mc_r12;
    frame.r13 = mc.mc_r13;
    frame.r14 = mc.mc_r14;
    frame.r15 = mc.mc_r15;
    frame.rip = mc.mc_rip;
    frame.rsp = mc.mc_rsp;
    frame.rflags = (mc.mc_rflags & PSL_USERCHANGE) | (frame.rflags & ~PSL_USERCHANGE);
    frame.cs = gdt_defs.UCODE_SEL;
    frame.ss = gdt_defs.UDATA_SEL;

    if (mc.mc_ownedfp != ucontext_md._MC_FPOWNED_NONE and mc.mc_fpformat == ucontext_md._MC_FPFMT_XMM) {
        var s: fpu.Savefpu = undefined;
        const raw: [*]const u8 = @ptrCast(mc);
        @memcpy(&s.data, raw[@offsetOf(Mcontext, "mc_fpstate")..][0..512]);
        fpu.sanitize(&s);
        fpu.fpurestore(&s);
    }
    if ((mc.mc_flags & ucontext_md._MC_HASBASES) != 0) {
        p.fsbase = mc.mc_fsbase;
        cpufunc.setFsBase(mc.mc_fsbase);
    }
    return true;
}

/// Divert the process to `catcher` for `sig` (FreeBSD's sendsig). `oldmask`
/// is the signal mask to restore when the handler returns. Returns false when
/// the frame cannot be placed (the caller then kills the process).
pub fn sendsig(frame: *TrapFrame, sig: u32, catcher: u64, siginfo: bool, oldmask: u64) bool {
    var sp: u64 = frame.rsp -% REDZONE;
    sp -%= @sizeOf(Sigframe);
    sp &= ~@as(u64, 15);
    if (sp < 4096 or sp >= VM_MAXUSER_ADDRESS) return false;

    const sf: *align(1) Sigframe = @ptrFromInt(sp);
    const raw: [*]u8 = @ptrCast(sf);
    @memset(raw[0..@sizeOf(Sigframe)], 0);
    sf.sf_ahu = catcher;
    getMcontext(frame, &sf.sf_uc.uc_mcontext, false);
    sf.sf_uc.uc_sigmask = ucontext.setOf(oldmask);
    sf.sf_si.si_signo = @intCast(sig);
    sf.sf_si.si_code = signal.SI_NOINFO;

    frame.rdi = sig;
    frame.rsi = if (siginfo) sp + @offsetOf(Sigframe, "sf_si") else 0;
    frame.rdx = sp + @offsetOf(Sigframe, "sf_uc");
    frame.rcx = 0;
    frame.rsp = sp;
    frame.rip = kern_exec.trampolineVa();
    frame.rflags &= ~(PSL_T | PSL_D);
    return true;
}

/// sigreturn(2): `sigreturn(ucp)`, return to the context a signal handler
/// interrupted, with its signal mask.
pub fn sysSigreturn(args: [sys.MAXARGS]u64) u64 {
    const frame = trap.currentFrame() orelse return sys.signed(-errno.EINVAL);
    if (args[0] == 0 or args[0] >= VM_MAXUSER_ADDRESS) return sys.signed(-errno.EFAULT);
    const uc: *align(1) const ucontext.Ucontext = @ptrFromInt(args[0]);
    if (!setMcontext(frame, &uc.uc_mcontext)) return sys.signed(-errno.EINVAL);
    kern_proc.current.sig_mask = ucontext.maskOf(uc.uc_sigmask) & ~signal.CANTMASK;
    return sys.signed(-errno.EJUSTRETURN);
}
