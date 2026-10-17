// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Resource limits and the file-creation mask.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_resource.c: each process
// holds a soft and hard limit per resource, inherited across fork and exec.
// The soft limit may move up to the hard limit; only root raises a hard limit.
// Renux records them all; the ones it enforces are noted below.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const proc: type = @import("../sys/proc.zig");
const kern_proc: type = @import("kern_proc.zig");
const arch: type = @import("../arch/arch.zig");
const subr_param: type = @import("subr_param.zig");
const param: type = @import("../sys/param.zig");
const user: type = @import("../sys/user.zig");

/// RLIM_INFINITY as a 64-bit signed value.
pub const RLIM_INFINITY: i64 = 0x7fff_ffff_ffff_ffff;

// FreeBSD's resources (sys/sys/resource.h).
const RLIMIT_STACK: usize = 3;
pub const RLIMIT_NOFILE: usize = 8;
const RLIMIT_NPROC: usize = 7;

/// The limits a new process starts with.
pub fn defaults() [proc.RLIM_NLIMITS]proc.Rlimit {
    var l: [proc.RLIM_NLIMITS]proc.Rlimit = @splat(.{ .cur = RLIM_INFINITY, .max = RLIM_INFINITY });
    // A finite stack limit: libthr places the main thread's guard page
    // relative to it, so RLIM_INFINITY would overflow the address.
    l[RLIMIT_STACK] = .{ .cur = 64 * 1024 * 1024, .max = 64 * 1024 * 1024 };
    // As FreeBSD's proc0: as many descriptors as the system holds files
    // (kern.maxfiles); kern.maxfilesperproc caps it per process.
    l[RLIMIT_NOFILE] = .{ .cur = subr_param.maxfiles, .max = subr_param.maxfiles };
    // The process table is fixed in size.
    l[RLIMIT_NPROC] = .{ .cur = 64, .max = 64 };
    return l;
}

/// getrlimit(2).
pub fn sysGetrlimit(args: [sys.MAXARGS]u64) u64 {
    if (args[0] >= proc.RLIM_NLIMITS) return sys.signed(-errno.EINVAL);
    if (args[1] == 0) return sys.signed(-errno.EFAULT);
    const dst: *align(1) proc.Rlimit = @ptrFromInt(args[1]);
    dst.* = kern_proc.current.rlimits[@intCast(args[0])];
    return 0;
}

/// setrlimit(2): the soft limit may not exceed the hard one, and only root
/// raises a hard limit. Limits backed by fixed tables cannot grow past them.
pub fn sysSetrlimit(args: [sys.MAXARGS]u64) u64 {
    if (args[0] >= proc.RLIM_NLIMITS) return sys.signed(-errno.EINVAL);
    if (args[1] == 0) return sys.signed(-errno.EFAULT);
    const p = kern_proc.current;
    const r: usize = @intCast(args[0]);
    const new: proc.Rlimit = @as(*align(1) const proc.Rlimit, @ptrFromInt(args[1])).*;
    if (new.cur < 0 or new.max < 0 or new.cur > new.max) return sys.signed(-errno.EINVAL);
    if (new.max > p.rlimits[r].max and p.euid != 0) return sys.signed(-errno.EPERM);
    var lim: proc.Rlimit = new;
    const ceiling: proc.Rlimit = defaults()[r];
    if (r == RLIMIT_NOFILE or r == RLIMIT_NPROC) {
        lim.cur = @min(lim.cur, ceiling.max);
        lim.max = @min(lim.max, ceiling.max);
    }
    // The stack is clamped to MAXSSIZ, as FreeBSD's kern_proc_setrlimit()
    // clamps it to maxssiz ("unlimited" from login.conf included).
    if (r == RLIMIT_STACK) {
        const maxssiz: i64 = @intCast(arch.vmparam.MAXSSIZ);
        lim.cur = @min(lim.cur, maxssiz);
        lim.max = @min(lim.max, maxssiz);
    }
    p.rlimits[r] = lim;
    return 0;
}

/// umask(2): set the file-creation mask, returning the old one.
pub fn sysUmask(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    const old: u16 = p.cmask;
    p.cmask = @truncate(args[0] & 0o777);
    return old;
}

/// getloginclass(2): `getloginclass(name, len)`.
pub fn sysGetloginclass(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    var n: usize = 0;
    while (n < p.loginclass.len and p.loginclass[n] != 0) n += 1;
    if (args[1] < n + 1) return sys.signed(-errno.ERANGE);
    const dst: [*]u8 = @ptrFromInt(args[0]);
    @memcpy(dst[0..n], p.loginclass[0..n]);
    dst[n] = 0;
    return 0;
}

/// setloginclass(2): root only; the class login.conf assigned.
pub fn sysSetloginclass(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    if (p.euid != 0) return sys.signed(-errno.EPERM);
    const src: [*:0]const u8 = @ptrFromInt(args[0]);
    var n: usize = 0;
    while (src[n] != 0) : (n += 1) {
        if (n + 1 >= p.loginclass.len) return sys.signed(-errno.ENAMETOOLONG);
    }
    @memset(&p.loginclass, 0);
    @memcpy(p.loginclass[0..n], src[0..n]);
    return 0;
}

/// Note the resident set of process `p` in its maximum (ru_maxrss). A vfork
/// child runs in its parent's pages, none of them its own.
pub fn sampleRss(p: *proc.Proc) void {
    if (p.pmap == 0 or p.vm_borrowed_from != null) return;
    const kb: u64 = arch.pmap.residentCount(p.pmap) * (param.PAGE_SIZE / 1024);
    p.usage.maxrss_kb = @max(p.usage.maxrss_kb, kb);
}

fn ticksToTimeval(t: u64) user.Timeval {
    const us: u64 = t * (1_000_000 / arch.clock.HZ);
    return .{ .sec = @intCast(us / 1_000_000), .usec = @intCast(us % 1_000_000) };
}

/// The struct rusage that reports `u` (FreeBSD's calcru and rufetch).
pub fn toRusage(u: proc.Usage) user.Rusage {
    var ru: user.Rusage = .{ .utime = ticksToTimeval(u.uticks), .stime = ticksToTimeval(u.sticks), .longs = @splat(0) };
    ru.longs[0] = @intCast(u.maxrss_kb); // ru_maxrss
    return ru;
}

const RUSAGE_SELF: i32 = 0;
const RUSAGE_CHILDREN: i32 = -1;
const RUSAGE_THREAD: i32 = 1;

/// getrusage(2): `getrusage(who, rusage)`, the resources the calling
/// process (RUSAGE_SELF, and RUSAGE_THREAD: Renux accounts per process) or
/// its reaped children (RUSAGE_CHILDREN) used.
pub fn sysGetrusage(args: [sys.MAXARGS]u64) u64 {
    const who: i32 = @bitCast(@as(u32, @truncate(args[0])));
    if (args[1] == 0) return sys.signed(-errno.EFAULT);
    const p: *proc.Proc = kern_proc.current;
    const u: proc.Usage = switch (who) {
        RUSAGE_SELF, RUSAGE_THREAD => blk: {
            sampleRss(p);
            break :blk p.usage;
        },
        RUSAGE_CHILDREN => p.usage_children,
        else => return sys.signed(-errno.EINVAL),
    };
    @as(*align(1) user.Rusage, @ptrFromInt(args[1])).* = toRusage(u);
    return 0;
}
