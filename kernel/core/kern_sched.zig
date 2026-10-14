// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Scheduler and kernel-thread switching.
//
// The Zig counterpart of NetBSD's sys/kern/sched_4bsd.c, reduced to a
// round-robin over runnable processes. Timer interrupts preempt the running
// process (the port's trap handler calls yield()); syscalls may block with sleep() and be
// resumed by wakeup().

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const tty: type = @import("tty.zig");
const vfs_bio: type = @import("vfs_bio.zig");
const vfs_mount: type = @import("vfs_mount.zig");
const prf: type = @import("subr_prf.zig");
const param: type = @import("../sys/param.zig");

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
    prf.log(prf.LOG_DEBUG, "sched: prepared context for pid %d", .{p.pid});
}

/// The scheduler loop. Runs on the boot stack and never returns.
pub fn scheduler() noreturn {
    while (true) {
        in_scheduler = true;
        var found: bool = false;

        // Typed control characters signal the foreground job promptly.
        tty.rint();

        for (&kern_proc.table) |*p| {
            if (p.state != .runnable) {
                continue;
            }
            found = true;
            p.state = .running;
            kern_proc.current = p;
            arch.gdt.setKernelStack(p.kstack_top);
            arch.syscall_entry.setKernelStack(p.kstack_top);
            // Reloading CR3 flushes the TLB: skip it when the process runs
            // in the address space already loaded (it was the last one).
            if (arch.pmap.current() != p.pmap) {
                arch.pmap.activate(p.pmap);
            }
            // Restore the process's user thread pointer (TLS base).
            arch.cpu.setFsBase(p.fsbase);
            // And its FPU registers (saved by sched() when it stopped).
            arch.fpu.fpurestore(&p.fpu);
            in_scheduler = false;
            arch.swtch.swtch(&sched_ctx, &p.context);
        }

        if (!found) {
            // Nothing runnable: let the syncer write aged buffers, then idle
            // until an interrupt arrives.
            vfs_bio.syncer(vfs_mount.diskBusy);
            arch.gdt.setKernelStack(schedStackTop());
            arch.syscall_entry.setKernelStack(schedStackTop());
            arch.cpu.enable_interrupts();
            arch.cpu.halt();
            arch.cpu.disable_interrupts();
        }
    }
}

/// Panic if the current process overran its kernel stack: the canary at the
/// bottom of the stack was overwritten. Without this, an overflow silently
/// corrupts whatever page follows the stack.
fn checkStack() void {
    const p = kern_proc.current;
    if (p.kstack_page == 0) return;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
    const canary: *const u64 = @ptrFromInt(p.kstack_page + hhdm);
    if (canary.* != param.KSTACK_CANARY) {
        prf.printf("pid %d (%s): kernel stack overflow\n", .{ p.pid, p.name[0..p.name_len] });
        prf.panic("kernel stack overflow", null);
    }
}

/// Give up the CPU and let the scheduler pick another process.
pub fn sched() void {
    checkStack();
    arch.fpu.fpusave(&kern_proc.current.fpu);
    arch.swtch.swtch(&kern_proc.current.context, &sched_ctx);
}

/// Voluntarily yield the CPU (still runnable).
pub fn yield() void {
    kern_proc.current.state = .runnable;
    sched();
}

/// Wait for I/O: sleep until a device or pipe reports activity (ioWakeup) or
/// the next clock tick, whichever comes first. A process waiting for input
/// therefore uses no CPU, and the tick bounds the wait for sources that
/// raise no interrupt (the polled serial port) to 10 ms. FreeBSD's tsleep()
/// on a per-object channel, with one shared channel.
pub fn ioWait() void {
    sleep(arch.clock.pollChannel());
}

/// Wake the processes waiting in ioWait() (or in poll(2)), because input
/// arrived, a pipe gained data or room, or an end closed.
pub fn ioWakeup() void {
    wakeup(arch.clock.pollChannel());
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
