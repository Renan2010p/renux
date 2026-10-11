// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
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
const vfs_subr: type = @import("vfs_subr.zig");

/// Fork the current process. Returns the child's pid in the parent, 0 in the
/// child, or -1 on failure.
pub fn fork(frame: *arch.trapframe.TrapFrame) i32 {
    const parent = kern_proc.current;
    const child = kern_proc.alloc() orelse return -1;
    child.parent = parent;

    const hhdm: u64 = arch.boot.hhdmOffset() orelse {
        kern_proc.free(child);
        return -1;
    };

    // Copy the parent's user pages into the child's address space.
    arch.pmap.copyUser(child.pmap, parent.pmap, hhdm);

    // The child resumes from the same user frame, but fork returns 0 in it.
    child.frame = frame.*;
    child.frame.rax = 0;

    // Inherit the open file table and the working directory.
    var fd: usize = 0;
    while (fd < proc.NFILE) : (fd += 1) {
        child.fds[fd] = parent.fds[fd];
        if (child.fds[fd]) |openfile| {
            openfile.f_count += 1;
        }
    }
    child.cwd = parent.cwd;
    if (child.cwd) |cwd| {
        vfs_subr.vref(cwd);
    }
    child.brk = parent.brk;
    child.mmap_next = parent.mmap_next;

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
    }
    child.sig_pending = 0;
    child.sig_mask = parent.sig_mask;

    kern_sched.prepareContext(child);
    child.state = .runnable;
    return child.pid;
}
