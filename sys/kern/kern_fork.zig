// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// fork(): create a child process.
//
// The Zig counterpart of NetBSD's sys/kern/kern_fork.c (simplified): the child
// gets a copy of the parent's address space and user frame, and its own kernel
// context that starts at procEntry.

const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");

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

    kern_sched.prepareContext(child);
    child.state = .runnable;
    return child.pid;
}
