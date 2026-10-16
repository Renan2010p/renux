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
pub const SYS_vfork: u64 = 66;
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
pub const SYS_madvise: u64 = 75;
pub const SYS_readlink: u64 = 58;
pub const SYS_readlinkat: u64 = 500;
pub const SYS_cpuset_getaffinity: u64 = 487;
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
pub const SYS_sync: u64 = 36;
pub const SYS_reboot: u64 = 55;
pub const SYS_link: u64 = 9;
pub const SYS_symlink: u64 = 57;
pub const SYS_linkat: u64 = 495;
pub const SYS_symlinkat: u64 = 502;
pub const SYS_unmount: u64 = 22;
pub const SYS_nmount: u64 = 378;
pub const SYS_statfs: u64 = 555;
pub const SYS_fstatfs: u64 = 556;
pub const SYS_getfsstat: u64 = 557;
pub const SYS_getcontext: u64 = 421;
pub const SYS_setcontext: u64 = 422;
pub const SYS_swapcontext: u64 = 423;
pub const SYS_sigsuspend: u64 = 341;
pub const SYS_sigpending: u64 = 343;
pub const SYS_mmap: u64 = 477;
pub const SYS___sysctl: u64 = 202;
pub const SYS___sysctlbyname: u64 = 570;
pub const SYS_getrlimit: u64 = 194;
pub const SYS_setrlimit: u64 = 195;
pub const SYS_fstatat: u64 = 552;
pub const SYS_clock_gettime: u64 = 232;
pub const SYS_writev: u64 = 121;
pub const SYS_access: u64 = 33;
pub const SYS_faccessat: u64 = 489;
pub const SYS_geteuid: u64 = 25;
pub const SYS_getegid: u64 = 43;
pub const SYS_fcntl: u64 = 92;
pub const SYS_openat: u64 = 499;
pub const SYS_readv: u64 = 120;
pub const SYS_preadv: u64 = 289;
pub const SYS_pwritev: u64 = 290;
pub const SYS_pread: u64 = 475;
pub const SYS_setsid: u64 = 147;
pub const SYS_getpgid: u64 = 207;
pub const SYS_getsid: u64 = 310;
pub const SYS_setlogin: u64 = 50;
pub const SYS_getpgrp: u64 = 81;
pub const SYS_setpgid: u64 = 82;
pub const SYS_fsync: u64 = 95;
pub const SYS_fdatasync: u64 = 550;
pub const SYS_ftruncate: u64 = 480;
pub const SYS_truncate: u64 = 479;
pub const SYS_chmod: u64 = 15;
pub const SYS_fchmod: u64 = 124;
pub const SYS_futimens: u64 = 546;
pub const SYS_utimensat: u64 = 547;
pub const SYS_rename: u64 = 128;
pub const SYS_getppid: u64 = 39;
pub const SYS_getgid: u64 = 47;
pub const SYS_poll: u64 = 209;

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
pub const SYS_lchmod: u64 = 274;
pub const SYS_fchmodat: u64 = 490;
pub const SYS_chown: u64 = 16;
pub const SYS_fchown: u64 = 123;
pub const SYS_lchown: u64 = 254;
pub const SYS_fchownat: u64 = 491;
pub const SYS_chflags: u64 = 34;
pub const SYS_fchflags: u64 = 35;
pub const SYS_lchflags: u64 = 391;
pub const SYS_chflagsat: u64 = 540;
pub const SYS_setgid: u64 = 181;
pub const SYS_setegid: u64 = 182;
pub const SYS_seteuid: u64 = 183;
pub const SYS_setreuid: u64 = 126;
pub const SYS_setregid: u64 = 127;
pub const SYS_getresuid: u64 = 360;
pub const SYS_getresgid: u64 = 361;
pub const SYS_getgroups: u64 = 79;
pub const SYS_setgroups: u64 = 80;
pub const SYS_getlogin: u64 = 49;
pub const SYS_getitimer: u64 = 86;
pub const SYS_setitimer: u64 = 83;
pub const SYS_nanosleep: u64 = 240;
pub const SYS_getpriority: u64 = 100;
pub const SYS_setpriority: u64 = 96;
pub const SYS_close_range: u64 = 575;
pub const SYS_minherit: u64 = 250;
pub const SYS_thr_self: u64 = 432;
pub const SYS_thr_kill: u64 = 433;
pub const SYS_getrandom: u64 = 563;
pub const SYS_mkdirat: u64 = 496;
pub const SYS_unlinkat: u64 = 503;
pub const SYS_fchdir: u64 = 13;
pub const SYS_umask: u64 = 60;
pub const SYS_getloginclass: u64 = 523;
pub const SYS_setloginclass: u64 = 524;
pub const SYS_pipe2: u64 = 542;
pub const SYS_renameat: u64 = 501;
pub const SYS_getdirentries: u64 = 554;
pub const SYS_pathconf: u64 = 191;
pub const SYS_fpathconf: u64 = 192;
pub const SYS_lpathconf: u64 = 513;
pub const SYS_clock_getres: u64 = 234;
pub const SYS_copy_file_range: u64 = 569;
pub const SYS_eaccess: u64 = 376;
pub const SYS_flock: u64 = 131;
pub const SYS_pwrite: u64 = 476;
pub const SYS_getdtablesize: u64 = 89;
pub const SYS_rtprio_thread: u64 = 466;
pub const SYS__umtx_op: u64 = 454;
pub const SYS_thr_wake: u64 = 443;
pub const SYS_thr_suspend: u64 = 442;
pub const SYS_pselect: u64 = 522;
pub const SYS_select: u64 = 93;
