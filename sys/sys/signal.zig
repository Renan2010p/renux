// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Signals.
//
// This is the Zig counterpart of NetBSD's sys/sys/signal.h, reduced to the
// signal numbers and the two special handler values. The numbers match
// NetBSD's.

/// Highest signal number plus one; signals are numbered 1..NSIG-1.
pub const NSIG: u32 = 32;

pub const SIGHUP: u32 = 1;
pub const SIGINT: u32 = 2;
pub const SIGQUIT: u32 = 3;
pub const SIGILL: u32 = 4;
pub const SIGTRAP: u32 = 5;
pub const SIGABRT: u32 = 6;
pub const SIGEMT: u32 = 7;
pub const SIGFPE: u32 = 8;
pub const SIGKILL: u32 = 9;
pub const SIGBUS: u32 = 10;
pub const SIGSEGV: u32 = 11;
pub const SIGSYS: u32 = 12;
pub const SIGPIPE: u32 = 13;
pub const SIGALRM: u32 = 14;
pub const SIGTERM: u32 = 15;
pub const SIGURG: u32 = 16;
pub const SIGSTOP: u32 = 17;
pub const SIGTSTP: u32 = 18;
pub const SIGCONT: u32 = 19;
pub const SIGCHLD: u32 = 20;
pub const SIGTTIN: u32 = 21;
pub const SIGTTOU: u32 = 22;
pub const SIGIO: u32 = 23;
pub const SIGXCPU: u32 = 24;
pub const SIGXFSZ: u32 = 25;
pub const SIGVTALRM: u32 = 26;
pub const SIGPROF: u32 = 27;
pub const SIGWINCH: u32 = 28;
pub const SIGINFO: u32 = 29;
pub const SIGUSR1: u32 = 30;
pub const SIGUSR2: u32 = 31;

/// The default handler.
pub const SIG_DFL: u64 = 0;
/// Ignore the signal.
pub const SIG_IGN: u64 = 1;

/// True when a signal's default action terminates the process.
pub fn defaultTerminates(sig: u32) bool {
    return switch (sig) {
        SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGEMT, SIGFPE, SIGKILL, SIGBUS, SIGSEGV, SIGSYS, SIGPIPE, SIGALRM, SIGTERM, SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF => true,
        else => false,
    };
}

/// sigaction(2) flags.
pub const SA_ONSTACK: u32 = 0x0001;
pub const SA_RESTART: u32 = 0x0002;
pub const SA_RESETHAND: u32 = 0x0004;
pub const SA_NODEFER: u32 = 0x0010;
pub const SA_NOCLDWAIT: u32 = 0x0020;
pub const SA_SIGINFO: u32 = 0x0040;

/// sigprocmask(2) operations.
pub const SIG_BLOCK: u64 = 1;
pub const SIG_UNBLOCK: u64 = 2;
pub const SIG_SETMASK: u64 = 3;

/// si_code values.
pub const SI_NOINFO: i32 = 0;
pub const SI_USER: i32 = 0x10001;

/// siginfo_t (80 bytes on amd64).
pub const Siginfo: type = extern struct {
    si_signo: i32,
    si_errno: i32,
    si_code: i32,
    si_pid: i32,
    si_uid: u32,
    si_status: i32,
    si_addr: u64,
    si_value: u64,
    _reason: [40]u8,
};

/// Signals that can be neither caught, blocked nor ignored.
pub const CANTMASK: u64 = (1 << SIGKILL) | (1 << SIGSTOP);
