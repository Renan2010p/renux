// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Kernel-to-user structures for process information.
//
// This is the Zig counterpart of FreeBSD's sys/sys/user.h, reduced to the
// struct kinfo_proc that sysctl(KERN_PROC) returns and that top(1)/htop(1) read.
// The layout (field order, sizes and the trailing variants) must match FreeBSD
// exactly: libkvm and htop were built against FreeBSD 14 and index the array by
// this size.

/// Maximum command name length (FreeBSD MAXCOMLEN).
pub const MAXCOMLEN: usize = 19;
/// Thread name, wchan message, lock name, login name and class sizes.
pub const TDNAMLEN: usize = 16;
pub const WMESGLEN: usize = 8;
pub const LOCKNAMELEN: usize = 8;
pub const COMMLEN: usize = 19;
pub const KI_EMULNAMELEN: usize = 16;
pub const KI_NGROUPS: usize = 16;
pub const LOGNAMELEN: usize = 17;
pub const LOGINCLASSLEN: usize = 17;
pub const KI_NSPARE_INT: usize = 2;
pub const KI_NSPARE_LONG: usize = 12;
pub const KI_NSPARE_PTR: usize = 5;

/// Signal set (FreeBSD __sigset_t): 4 32-bit words.
pub const Sigset: type = extern struct { bits: [4]u32 };

/// A struct timeval, as embedded in kinfo_proc.
pub const Timeval: type = extern struct { sec: i64, usec: i64 };

/// Scheduling priority (FreeBSD struct priority).
pub const Priority: type = extern struct {
    class: u8,
    level: u8,
    native: u8,
    user: u8,
};

/// Resource usage (FreeBSD struct rusage): 144 bytes.
pub const Rusage: type = extern struct {
    utime: Timeval,
    stime: Timeval,
    longs: [14]i64,
};

/// FreeBSD's struct kinfo_proc.
pub const KinfoProc: type = extern struct {
    ki_structsize: i32,
    ki_layout: i32,
    ki_args: ?*anyopaque,
    ki_paddr: ?*anyopaque,
    ki_addr: ?*anyopaque,
    ki_tracep: ?*anyopaque,
    ki_textvp: ?*anyopaque,
    ki_fd: ?*anyopaque,
    ki_vmspace: ?*anyopaque,
    ki_wchan: ?*anyopaque,
    ki_pid: i32,
    ki_ppid: i32,
    ki_pgid: i32,
    ki_tpgid: i32,
    ki_sid: i32,
    ki_tsid: i32,
    ki_jobc: i16,
    ki_spare_short1: i16,
    ki_tdev_freebsd11: u32,
    ki_siglist: Sigset,
    ki_sigmask: Sigset,
    ki_sigignore: Sigset,
    ki_sigcatch: Sigset,
    ki_uid: u32,
    ki_ruid: u32,
    ki_svuid: u32,
    ki_rgid: u32,
    ki_svgid: u32,
    ki_ngroups: i16,
    ki_spare_short2: i16,
    ki_groups: [KI_NGROUPS]u32,
    ki_size: u64,
    ki_rssize: i64,
    ki_swrss: i64,
    ki_tsize: i64,
    ki_dsize: i64,
    ki_ssize: i64,
    ki_xstat: u16,
    ki_acflag: u16,
    ki_pctcpu: u32,
    ki_estcpu: u32,
    ki_slptime: u32,
    ki_swtime: u32,
    ki_cow: u32,
    ki_runtime: u64,
    ki_start: Timeval,
    ki_childtime: Timeval,
    ki_flag: i64,
    ki_kiflag: i64,
    ki_traceflag: i32,
    ki_stat: u8,
    ki_nice: i8,
    ki_lock: u8,
    ki_rqindex: u8,
    ki_oncpu_old: u8,
    ki_lastcpu_old: u8,
    ki_tdname: [TDNAMLEN + 1]u8,
    ki_wmesg: [WMESGLEN + 1]u8,
    ki_login: [LOGNAMELEN + 1]u8,
    ki_lockname: [LOCKNAMELEN + 1]u8,
    ki_comm: [COMMLEN + 1]u8,
    ki_emul: [KI_EMULNAMELEN + 1]u8,
    ki_loginclass: [LOGINCLASSLEN + 1]u8,
    ki_moretdname: [MAXCOMLEN - TDNAMLEN + 1]u8,
    ki_sparestrings: [46]u8,
    ki_spareints: [KI_NSPARE_INT]i32,
    ki_tdev: u64,
    ki_oncpu: i32,
    ki_lastcpu: i32,
    ki_tracer: i32,
    ki_flag2: i32,
    ki_fibnum: i32,
    ki_cr_flags: u32,
    ki_jid: i32,
    ki_numthreads: i32,
    ki_tid: i32,
    ki_pri: Priority,
    ki_rusage: Rusage,
    ki_rusage_ch: Rusage,
    ki_pcb: ?*anyopaque,
    ki_kstack: ?*anyopaque,
    ki_udata: ?*anyopaque,
    ki_tdaddr: ?*anyopaque,
    ki_pd: ?*anyopaque,
    ki_spareptrs: [KI_NSPARE_PTR]?*anyopaque,
    ki_sparelongs: [KI_NSPARE_LONG]i64,
    ki_sflag: i64,
    ki_tdflags: i64,
};
