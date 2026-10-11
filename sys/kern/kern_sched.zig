// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Scheduler and kernel-thread switching.
//
// The Zig counterpart of NetBSD's sys/kern/sched_4bsd.c, reduced to a
// round-robin over runnable processes. Timer interrupts preempt the running
// process (kern/trap.zig calls yield()); syscalls may block with sleep() and be
// resumed by wakeup().

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");

/// True while the scheduler itself is running (so a timer interrupt must not
/// try to preempt it).
pub var in_scheduler: bool = true;

/// Context the scheduler switches away from and back to.
var sched_ctx: proc.Context = .{ .rsp = 0, .rbx = 0, .rbp = 0, .r12 = 0, .r13 = 0, .r14 = 0, .r15 = 0, .rip = 0 };

/// Dedicated stack used while the scheduler idles.
var sched_stack: [8192]u8 align(16) = undefined;

fn schedStackTop() u64 {
    return @intFromPtr(&sched_stack) + @sizeOf(@TypeOf(sched_stack));
}

/// First function a newly created process runs: it returns to ring 3 with the
/// process's stored frame.
fn procEntry() callconv(.c) noreturn {
    arch.trap.usertrapret(&kern_proc.current.frame);
}

/// Prepare a process's kernel context so that the first swtch() to it lands in
/// procEntry().
pub fn prepareContext(p: *proc.Proc) void {
    p.context = .{
        .rsp = p.kstack_top,
        .rbx = 0,
        .rbp = 0,
        .r12 = 0,
        .r13 = 0,
        .r14 = 0,
        .r15 = 0,
        .rip = @intFromPtr(&procEntry),
    };
}

/// The scheduler loop. Runs on the boot stack and never returns.
pub fn scheduler() noreturn {
    while (true) {
        in_scheduler = true;
        var found: bool = false;

        for (&kern_proc.table) |*p| {
            if (p.state != .runnable) {
                continue;
            }
            found = true;
            p.state = .running;
            kern_proc.current = p;
            arch.gdt.setKernelStack(p.kstack_top);
            arch.pmap.activate(p.pmap);
            in_scheduler = false;
            arch.swtch.swtch(&sched_ctx, &p.context);
        }

        if (!found) {
            // Nothing runnable: idle until an interrupt arrives.
            arch.gdt.setKernelStack(schedStackTop());
            arch.cpu.enable_interrupts();
            arch.cpu.halt();
            arch.cpu.disable_interrupts();
        }
    }
}

/// Give up the CPU and let the scheduler pick another process.
pub fn sched() void {
    arch.swtch.swtch(&kern_proc.current.context, &sched_ctx);
}

/// Voluntarily yield the CPU (still runnable).
pub fn yield() void {
    kern_proc.current.state = .runnable;
    sched();
}

/// Block the current process on `chan` until wakeup(chan).
pub fn sleep(chan: ?*anyopaque) void {
    kern_proc.current.chan = chan;
    kern_proc.current.state = .sleeping;
    sched();
    kern_proc.current.chan = null;
}

/// Wake every process sleeping on `chan`.
pub fn wakeup(chan: ?*anyopaque) void {
    for (&kern_proc.table) |*p| {
        if (p.state == .sleeping and p.chan == chan) {
            p.state = .runnable;
        }
    }
}
