// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Advisory file locks.
//
// The counterpart of the flock(2) half of FreeBSD's sys/kern/kern_lockf.c: a
// whole-file lock, shared (many holders) or exclusive (one), held by an open
// file and released when that file is closed. Conflicting requests wait,
// unless LOCK_NB asks for EWOULDBLOCK instead. Byte-range (fcntl F_SETLK)
// locks are not implemented yet.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const file: type = @import("../sys/file.zig");
const vnode: type = @import("../sys/vnode.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_signal: type = @import("kern_signal.zig");

const LOCK_SH: u64 = 0x01;
const LOCK_EX: u64 = 0x02;
const LOCK_NB: u64 = 0x04;
const LOCK_UN: u64 = 0x08;

fn vnodeOf(f: *file.File) ?*vnode.Vnode {
    if (f.f_type != file.DTYPE_VNODE) return null;
    return @ptrCast(@alignCast(f.f_data orelse return null));
}

/// Drop the lock `f` holds, if any (also called when `f` is closed).
pub fn release(f: *file.File) void {
    const vp: *vnode.Vnode = vnodeOf(f) orelse return;
    switch (f.f_lock) {
        .none => return,
        .shared => vp.v_lock_shared -= 1,
        .exclusive => vp.v_lock_excl = null,
    }
    f.f_lock = .none;
    kern_sched.ioWakeup(); // let a waiting locker retry
}

/// Whether `f` may take the lock now.
fn grantable(vp: *vnode.Vnode, f: *file.File, exclusive: bool) bool {
    if (vp.v_lock_excl) |holder| {
        if (holder != @as(*anyopaque, @ptrCast(f))) return false;
    }
    if (exclusive) {
        const own: u32 = if (f.f_lock == .shared) 1 else 0;
        return vp.v_lock_shared - own == 0;
    }
    return true;
}

/// flock(2): `flock(fd, operation)`.
pub fn sysFlock(args: [sys.MAXARGS]u64) u64 {
    const p = kern_proc.current;
    const f: *file.File = kern_descrip.fdGetfile(p, @intCast(args[0])) orelse return sys.signed(-errno.EBADF);
    const op: u64 = args[1];
    const vp: *vnode.Vnode = vnodeOf(f) orelse return sys.signed(-errno.EOPNOTSUPP);

    if ((op & LOCK_UN) != 0) {
        release(f);
        return 0;
    }
    const exclusive: bool = (op & LOCK_EX) != 0;
    if (!exclusive and (op & LOCK_SH) == 0) return sys.signed(-errno.EINVAL);

    while (!grantable(vp, f, exclusive)) {
        if ((op & LOCK_NB) != 0) return sys.signed(-errno.EWOULDBLOCK);
        if (kern_signal.interrupted(p)) return sys.signed(-errno.EINTR);
        kern_sched.ioWait();
    }
    // Convert a lock already held, then take the new one.
    release(f);
    if (exclusive) {
        vp.v_lock_excl = f;
        f.f_lock = .exclusive;
    } else {
        vp.v_lock_shared += 1;
        f.f_lock = .shared;
    }
    return 0;
}
