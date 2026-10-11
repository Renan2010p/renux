// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// exit() and wait().
//
// The Zig counterpart of NetBSD's sys/kern/kern_exit.c (simplified): a process
// that exits becomes a zombie until its parent reaps it with wait(); a parent
// with no zombie child sleeps on itself and is woken when a child exits.

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");

/// Terminate the current process with `status`. Never returns.
pub fn exit(status: i32) noreturn {
    const p = kern_proc.current;
    p.exit_status = status;
    p.state = .zombie;

    // Wake a parent blocked in wait().
    if (p.parent) |parent| {
        kern_sched.wakeup(@ptrCast(parent));
    }

    // Switch away; being a zombie, this process is never scheduled again.
    kern_sched.sched();
    arch.cpu.idle();
}

/// Wait for any child to exit and reap it. Returns the child's pid and stores
/// its exit status in `status_out`, or -1 if there is no child.
pub fn wait(status_out: *i32) i32 {
    const parent = kern_proc.current;

    while (true) {
        for (&kern_proc.table) |*c| {
            if (c.state == .zombie and c.parent == parent) {
                const pid: i32 = c.pid;
                status_out.* = c.exit_status;
                kern_proc.free(c);
                return pid;
            }
        }

        var has_child: bool = false;
        for (&kern_proc.table) |*c| {
            if (c.state != .unused and c.parent == parent) {
                has_child = true;
            }
        }
        if (!has_child) {
            return -1;
        }

        kern_sched.sleep(@ptrCast(parent));
    }
}
