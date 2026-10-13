// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Thread calls.
//
// The Zig counterpart of the single-thread part of FreeBSD's
// sys/kern/kern_thr.c. Renux processes have exactly one thread, whose id is
// the pid offset into FreeBSD's thread-id range (FreeBSD numbers threads from
// 100000 up, apart from pids). libc asks for it even in programs that never
// create threads: raise(3) and abort(3) signal the calling thread.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const signal: type = @import("../sys/signal.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_signal: type = @import("kern_signal.zig");

/// First thread id.
pub const TID_BASE: i64 = 100000;

/// The id of the only thread of process `pid`.
pub fn tidOf(pid: i32) i64 {
    return TID_BASE + pid;
}

/// thr_self(2): `thr_self(long *id)`.
pub fn sysThrSelf(args: [sys.MAXARGS]u64) u64 {
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const dst: *align(1) i64 = @ptrFromInt(args[0]);
    dst.* = tidOf(kern_proc.current.pid);
    return 0;
}

/// thr_kill(2): `thr_kill(long id, int sig)`; only the calling thread exists.
pub fn sysThrKill(args: [sys.MAXARGS]u64) u64 {
    const id: i64 = @bitCast(args[0]);
    const sig: u64 = args[1];
    const p = kern_proc.current;
    if (id != tidOf(p.pid) and id != -1) return sys.signed(-errno.ESRCH);
    if (sig >= signal.NSIG) return sys.signed(-errno.EINVAL);
    if (sig != 0) kern_signal.psignal(p, @intCast(sig));
    return 0;
}
