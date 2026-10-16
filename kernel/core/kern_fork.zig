// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// fork(): create a child process.
//
// The Zig counterpart of NetBSD's sys/kern/kern_fork.c (simplified): the child
// gets a copy of the parent's address space and user frame, and its own kernel
// context that starts at procEntry.

const arch: type = @import("../arch/arch.zig");
const proc: type = @import("../sys/proc.zig");
const signal: type = @import("../sys/signal.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const prf: type = @import("subr_prf.zig");
const param: type = @import("../sys/param.zig");

/// Fork the current process. Returns the child's pid in the parent, 0 in the
/// child, or -1 on failure.
pub fn fork(frame: *arch.trapframe.TrapFrame) i32 {
    const parent = kern_proc.current;
    const child = kern_proc.alloc() orelse return -1;
    child.parent = parent;
    prf.log(prf.LOG_DEBUG, "fork: %d -> %d", .{ parent.pid, child.pid });

    const hhdm: u64 = arch.boot.hhdmOffset() orelse {
        kern_proc.free(child);
        return -1;
    };

    // Copy the parent's user pages into the child's address space, then zero
    // the ranges marked INHERIT_ZERO (minherit(2)).
    arch.pmap.copyUser(child.pmap, parent.pmap, hhdm);
    child.inherit_zero = parent.inherit_zero;
    child.anon = parent.anon;
    for (parent.inherit_zero) |r| {
        var va: u64 = r.start;
        while (va < r.end) : (va += param.PAGE_SIZE) {
            const pa: u64 = arch.pmap.extract(child.pmap, va) orelse continue;
            const page: [*]u8 = @ptrFromInt((pa & ~@as(u64, param.PAGE_SIZE - 1)) + hhdm);
            @memset(page[0..param.PAGE_SIZE], 0);
        }
    }

    // The child resumes from the same user frame, but fork() returns 0 in it.
    // The carry flag must be cleared too: FreeBSD's fork stub branches to its
    // error path (returning -1 with an unchanged errno) when the flag is set, so
    // inheriting the parent's carry from a previous failed syscall would make
    // fork() look like it failed in the child.
    child.frame = frame.*;
    child.frame.rax = 0;
    child.frame.rflags &= ~@as(u64, 1);

    // Inherit the open file table and the working directory.
    if (!kern_descrip.fdcopy(parent, child)) {
        kern_proc.free(child);
        return -1;
    }
    child.cwd = parent.cwd;
    if (child.cwd) |cwd| {
        vfs_subr.vref(cwd);
    }
    child.brk = parent.brk;
    child.mmap_next = parent.mmap_next;
    child.uid = parent.uid;
    child.euid = parent.euid;
    child.svuid = parent.svuid;
    child.gid = parent.gid;
    child.egid = parent.egid;
    child.svgid = parent.svgid;
    child.ngroups = parent.ngroups;
    child.groups = parent.groups;
    child.login = parent.login;
    child.loginclass = parent.loginclass;
    child.cmask = parent.cmask;
    child.rlimits = parent.rlimits;
    // The child shares the parent's thread pointer (TLS) until it execs; without
    // this, libc's per-thread state (errno, ...) faults on the first access.
    child.fsbase = parent.fsbase;

    // The child runs the same program until it execs (FreeBSD's p_comm).
    child.name = parent.name;
    child.name_len = parent.name_len;
    child.exe_path = parent.exe_path;
    child.exe_path_len = parent.exe_path_len;

    // Copy the working-directory path.
    var k: usize = 0;
    while (k < parent.cwd_len) : (k += 1) {
        child.cwd_path[k] = parent.cwd_path[k];
    }
    child.cwd_len = parent.cwd_len;

    // Inherit the signal handlers; pending signals are not inherited.
    var sg: usize = 0;
    while (sg < signal.NSIG) : (sg += 1) {
        child.sig_handler[sg] = parent.sig_handler[sg];
        child.sig_flags[sg] = parent.sig_flags[sg];
        child.sig_actmask[sg] = parent.sig_actmask[sg];
    }
    child.sig_pending = 0;
    // Timers are not inherited (POSIX); the nice value is.
    child.itimer_due = 0;
    child.itimer_interval = 0;
    child.nice = parent.nice;
    child.sig_mask = parent.sig_mask;
    // The child joins the parent's process group and session.
    // The parent's FPU state is live in the registers.
    arch.fpu.fpusave(&child.fpu);
    child.pgid = parent.pgid;
    child.sid = parent.sid;

    kern_sched.prepareContext(child);
    child.state = .runnable;
    return child.pid;
}
