// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The scheduler.
//
// The Zig counterpart of FreeBSD's sys/kern/sched_4bsd.c, reduced to a
// round-robin over runnable threads on one CPU. The clock interrupt preempts
// the running thread (the port's trap handler calls yield()); a thread that
// must wait in the kernel sleeps on a channel with sleep() and is made
// runnable again by wakeup() on that channel, by a signal, or when its
// timed sleep runs out (sleepUntil, checked on every clock tick).
//
// A process that is stopped (job control) has none of its threads run.

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

/// First function a new thread runs: it enters ring 3 with the thread's
/// stored frame.
fn threadEntry() callconv(.c) noreturn {
    arch.trap.usertrapret(&kern_proc.curthread.frame);
}

/// Prepare thread `td`'s kernel context so that the first swtch() to it
/// lands in threadEntry().
pub fn prepareContext(td: *proc.Thread) void {
    td.context = .{
        .rsp = td.kstack_top,
        .rbx = 0,
        .rbp = 0,
        .r12 = 0,
        .r13 = 0,
        .r14 = 0,
        .r15 = 0,
        .rip = @intFromPtr(&threadEntry),
    };
}

/// The scheduler loop. Runs on the boot stack and never returns.
pub fn scheduler() noreturn {
    while (true) {
        in_scheduler = true;
        var found: bool = false;

        // Typed control characters signal the foreground job promptly.
        tty.rint();

        for (&kern_proc.threads) |*td| {
            // A thread that exited is freed here, now that nothing runs on
            // its kernel stack any more.
            if (td.state == .dead) {
                kern_proc.threadRelease(td);
                continue;
            }
            if (td.state != .runnable or td.proc.state != .active) {
                continue;
            }
            found = true;
            const p: *proc.Proc = td.proc;
            td.state = .running;
            kern_proc.curthread = td;
            kern_proc.current = p;
            arch.gdt.setKernelStack(td.kstack_top);
            arch.syscall_entry.setKernelStack(td.kstack_top);
            // Reloading CR3 flushes the TLB: skip it when the thread runs
            // in the address space already loaded (its process's, or a
            // sibling thread's).
            if (arch.pmap.current() != p.pmap) {
                arch.pmap.activate(p.pmap);
            }
            // Restore the thread's user thread pointer (TLS base).
            arch.cpu.setFsBase(td.fsbase);
            // And its FPU registers (saved by sched() when it stopped).
            arch.fpu.fpurestore(&td.fpu);
            in_scheduler = false;
            arch.swtch.swtch(&sched_ctx, &td.context);
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

/// Panic if the running thread overran its kernel stack: the canary at the
/// bottom of the stack was overwritten. Without this, an overflow silently
/// corrupts whatever page follows the stack.
fn checkStack() void {
    const td: *proc.Thread = kern_proc.curthread;
    if (td.kstack_page == 0) return;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
    const canary: *const u64 = @ptrFromInt(td.kstack_page + hhdm);
    if (canary.* != param.KSTACK_CANARY) {
        const p: *proc.Proc = td.proc;
        prf.printf("pid %d tid %d (%s): kernel stack overflow\n", .{ p.pid, td.tid, p.name[0..p.name_len] });
        prf.panic("kernel stack overflow", null);
    }
}

/// Give up the CPU and let the scheduler pick another thread.
pub fn sched() void {
    checkStack();
    const td: *proc.Thread = kern_proc.curthread;
    arch.fpu.fpusave(&td.fpu);
    arch.swtch.swtch(&td.context, &sched_ctx);
}

/// Voluntarily yield the CPU (still runnable).
pub fn yield() void {
    kern_proc.curthread.state = .runnable;
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

/// Block the running thread on `chan` until wakeup(chan) (or a signal, see
/// kern_signal).
pub fn sleep(chan: ?*anyopaque) void {
    sleepUntil(chan, 0);
}

/// Block the running thread on `chan` until wakeup(chan), a signal, or
/// clock tick `deadline` (0: no deadline).
pub fn sleepUntil(chan: ?*anyopaque, deadline: u64) void {
    const td: *proc.Thread = kern_proc.curthread;
    td.chan = chan;
    td.wake_tick = deadline;
    td.state = .sleeping;
    sched();
    td.chan = null;
    td.wake_tick = 0;
}

/// Wake every thread sleeping on `chan`.
pub fn wakeup(chan: ?*anyopaque) void {
    for (&kern_proc.threads) |*td| {
        if (td.state == .sleeping and td.chan == chan) {
            td.state = .runnable;
        }
    }
}

/// Make thread `td` runnable if it sleeps (on any channel): a signal or an
/// exit asks it to look.
pub fn wakeThread(td: *proc.Thread) void {
    if (td.state == .sleeping) td.state = .runnable;
}

/// Wake the threads whose timed sleep ended at clock tick `ticks` (called
/// on every tick).
pub fn wakeTimedOut(ticks: u64) void {
    for (&kern_proc.threads) |*td| {
        if (td.state == .sleeping and td.wake_tick != 0 and ticks >= td.wake_tick) {
            td.state = .runnable;
        }
    }
}
