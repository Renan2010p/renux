// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Sleepable exclusive locks.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_sx.c, exclusive mode only.
// A thread can be preempted inside a system call (reads and writes run with
// interrupts enabled), so state that a long operation updates in several
// steps -- a filesystem's bitmaps, directories and buffers -- is guarded by
// one of these: a second thread that wants it sleeps until the owner
// releases it. The owner may take it again (recursion), as a filesystem
// operation that calls another one does.

const proc: type = @import("../sys/proc.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");

pub const Sx: type = struct {
    owner: ?*proc.Thread = null,
    recurse: u32 = 0,
    /// Name, for diagnostics.
    name: []const u8 = "sx",
};

/// Take `sx` exclusively, sleeping while another thread holds it.
pub fn xlock(sx: *Sx) void {
    const td: *proc.Thread = kern_proc.curthread;
    if (sx.owner == td) {
        sx.recurse += 1;
        return;
    }
    while (sx.owner) |o| {
        // An owner that died holding the lock cannot release it.
        if (o.state == .unused or o.state == .dead) break;
        kern_sched.sleep(@ptrCast(sx));
    }
    sx.owner = td;
    sx.recurse = 0;
}

/// Release `sx`, waking the threads waiting for it.
pub fn xunlock(sx: *Sx) void {
    if (sx.recurse > 0) {
        sx.recurse -= 1;
        return;
    }
    sx.owner = null;
    kern_sched.wakeup(@ptrCast(sx));
}

/// True when someone holds `sx` (the syncer leaves a busy filesystem alone).
pub fn xlocked(sx: *const Sx) bool {
    return sx.owner != null;
}
