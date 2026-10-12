// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Process table.
//
// The Zig counterpart of NetBSD's sys/kern/kern_proc.c, reduced to what early
// multitasking needs: a fixed table of processes, pid allocation, and creation.

const proc: type = @import("../sys/proc.zig");
const arch: type = @import("../arch/arch.zig");
const signal: type = @import("../sys/signal.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");
const descrip: type = @import("kern_descrip.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const prf: type = @import("subr_prf.zig");

/// Maximum number of processes. FreeBSD's init restarts a getty as soon as it
/// exits, so a supervisor-style userland easily keeps several processes (a
/// session child per tty plus the getty itself); 64 leaves plenty of headroom
/// for those and for reaped-but-not-yet-collected zombies.
pub const NPROC: usize = 64;

pub var table: [NPROC]proc.Proc = undefined;
pub var current: *proc.Proc = undefined;

var next_pid: i32 = 1;

/// Initialise the process table.
pub fn init() void {
    for (&table) |*p| {
        p.pid = 0;
        p.state = .unused;
        p.parent = null;
        p.exit_status = 0;
        p.pmap = 0;
        p.kstack_page = 0;
        p.kstack_top = 0;
        p.context = .{ .rsp = 0, .rbx = 0, .rbp = 0, .r12 = 0, .r13 = 0, .r14 = 0, .r15 = 0, .rip = 0 };
        p.chan = null;
        var fd: usize = 0;
        while (fd < proc.NFILE) : (fd += 1) {
            p.fds[fd] = null;
        }
        p.cwd = null;
        p.cwd_len = 0;
        p.brk = 0;
        p.mmap_next = 0;
        p.uid = 0;
        p.sig_pending = 0;
        p.sig_mask = 0;
        var s: usize = 0;
        while (s < signal.NSIG) : (s += 1) {
            p.sig_handler[s] = 0;
        }
    }
    prf.printLine("proc: process table, 64 slots");
}

/// Allocate a process with a fresh address space and kernel stack.
pub fn alloc() ?*proc.Proc {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;

    for (&table) |*p| {
        if (p.state != .unused) {
            continue;
        }
        const map = arch.pmap.create() orelse return null;
        const kpage = uvm_page.physalloc() orelse return null;
        p.pid = next_pid;
        next_pid += 1;
        p.parent = null;
        p.exit_status = 0;
        p.pmap = map;
        p.kstack_page = kpage;
        p.kstack_top = kpage + hhdm + param.PAGE_SIZE;
        p.context = .{ .rsp = 0, .rbx = 0, .rbp = 0, .r12 = 0, .r13 = 0, .r14 = 0, .r15 = 0, .rip = 0 };
        p.chan = null;
        var fd: usize = 0;
        while (fd < proc.NFILE) : (fd += 1) {
            p.fds[fd] = null;
        }
        p.cwd = null;
        p.cwd_len = 0;
        p.brk = 0;
        p.mmap_next = 0;
        p.uid = 0;
        p.sig_pending = 0;
        p.sig_mask = 0;
        var s: usize = 0;
        while (s < signal.NSIG) : (s += 1) {
            p.sig_handler[s] = 0;
        }
        p.state = .runnable;
        return p;
    }
    return null;
}

/// Release a process.
pub fn free(p: *proc.Proc) void {
    descrip.fd_closeAll(p);
    if (p.cwd) |cwd| {
        vfs_subr.vrele(cwd);
        p.cwd = null;
    }
    if (p.pmap != 0) {
        if (arch.boot.hhdmOffset()) |off| {
            arch.pmap.destroy(p.pmap, off);
        }
    }
    if (p.kstack_page != 0) {
        uvm_page.physfree(p.kstack_page);
    }
    p.state = .unused;
    p.pid = 0;
    p.pmap = 0;
    p.kstack_page = 0;
    p.kstack_top = 0;
}
