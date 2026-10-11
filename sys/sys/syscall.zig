// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// System call numbers.
//
// Renux follows the FreeBSD x86-64 system call ABI, so programs built for
// FreeBSD run unchanged: the numbers below are FreeBSD's, the call is made with
// the `syscall` instruction and an error is reported by setting the carry flag
// with the errno in rax. (The legacy int 0x80 entry remains for bring-up.)
//
// NetBSD and FreeBSD both generate this from syscalls.master; Renux lists the
// calls it implements.

pub const SYS_exit: u64 = 1;
pub const SYS_fork: u64 = 2;
pub const SYS_read: u64 = 3;
pub const SYS_write: u64 = 4;
pub const SYS_open: u64 = 5;
pub const SYS_close: u64 = 6;
pub const SYS_wait4: u64 = 7;
pub const SYS_unlink: u64 = 10;
pub const SYS_chdir: u64 = 12;
pub const SYS_brk: u64 = 17;
pub const SYS_lseek: u64 = 478;
pub const SYS_getpid: u64 = 20;
pub const SYS_setuid: u64 = 23;
pub const SYS_getuid: u64 = 24;
pub const SYS_kill: u64 = 37;
pub const SYS_dup: u64 = 41;
pub const SYS_sigaction: u64 = 416;
pub const SYS_sigprocmask: u64 = 340;
pub const SYS_ioctl: u64 = 54;
pub const SYS_execve: u64 = 59;
pub const SYS_dup2: u64 = 90;
pub const SYS_mprotect: u64 = 74;
pub const SYS_munmap: u64 = 73;
pub const SYS_gettimeofday: u64 = 116;
pub const SYS_sysarch: u64 = 165;
pub const SYS_mkdir: u64 = 136;
pub const SYS_rmdir: u64 = 137;
pub const SYS_stat: u64 = 552; // modern stat(2) is fstatat(2) (FreeBSD 14)
pub const SYS_issetugid: u64 = 253;
pub const SYS_fstat: u64 = 551;
pub const SYS_getdents: u64 = 272;
pub const SYS_getcwd: u64 = 326;
/// Renux extension (FreeBSD numbers stop below 600): read the kernel message
/// buffer. Not part of the FreeBSD ABI, so it lives outside its range.
pub const SYS_klog: u64 = 600;
pub const SYS_sigreturn: u64 = 417;
pub const SYS_mmap: u64 = 477;
pub const SYS___sysctl: u64 = 202;
pub const SYS___sysctlbyname: u64 = 570;
pub const SYS_getrlimit: u64 = 194;
pub const SYS_setrlimit: u64 = 195;
pub const SYS_fstatat: u64 = 552;
pub const SYS_clock_gettime: u64 = 232;
pub const SYS_writev: u64 = 121;

/// Maximum argument count passed in registers.
pub const MAXARGS: usize = 6;

/// Highest system call number plus one.
pub const MAXSYSCALL: usize = 1024;

/// Error return value (a negative errno as unsigned).
pub const ERROR: u64 = @bitCast(@as(i64, -1));

/// Reinterpret a signed value as the unsigned system call result.
pub fn signed(value: i64) u64 {
    return @bitCast(value);
}
