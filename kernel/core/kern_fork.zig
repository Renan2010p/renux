// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// fork(), vfork() and rfork(): create a child process.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_fork.c. All three go
// through fork1, which makes a child with one thread, a copy of the calling
// thread, and either
//
//   - a copy of the parent's address space, its pages shared copy-on-write
//     (fork), or
//   - the parent's address space itself, borrowed until the child execs or
//     exits, while the parent waits (vfork, and rfork(RFSPAWN), which
//     posix_spawn(3) uses): nothing is copied at all, and what the child
//     writes before exec'ing (posix_spawn's error report) the parent sees.
//
// As FreeBSD's cpu_fork does, the system call returns in two registers:
// rax holds the child's pid in the parent and 0 in the child, and rdx 0 in
// the parent and 1 in the child (rfork_thread(3) tells them apart by rdx).

const arch: type = @import("../arch/arch.zig");
const proc: type = @import("../sys/proc.zig");
const signal: type = @import("../sys/signal.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const vm_map: type = @import("../vm/vm_map.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const prf: type = @import("subr_prf.zig");
const param: type = @import("../sys/param.zig");
const errno: type = @import("../sys/errno.zig");

/// What kind of child fork1 makes.
pub const Options: type = struct {
    /// Borrow the parent's address space instead of copying it (RFMEM).
    share_vm: bool = false,
    /// The parent waits until the child execs or exits (RFPPWAIT).
    ppwait: bool = false,
    /// Caught signals revert to their default action in the child
    /// (FreeBSD's FR2_DROPSIG_CAUGHT, for rfork(RFSPAWN)).
    drop_caught_signals: bool = false,
};

/// Fork the current process (FreeBSD's fork1). The child has one thread, a
/// copy of the calling one (as in FreeBSD: the other threads are not
/// copied). Returns the child's pid in the parent, or -1 on failure.
pub fn fork1(frame: *arch.trapframe.TrapFrame, options: Options) i32 {
    const parent: *proc.Proc = kern_proc.current;
    const caller: *proc.Thread = kern_proc.curthread;
    const child_td: *proc.Thread = kern_proc.alloc() orelse return -1;
    const child: *proc.Proc = child_td.proc;
    child.parent = parent;
    prf.log(prf.LOG_DEBUG, "fork: %d -> %d", .{ parent.pid, child.pid });

    if (options.share_vm) {
        // Run in the parent's address space (the one it borrows itself, if
        // it is a vfork child too): drop the fresh page tables alloc made.
        const owner: *proc.Proc = parent.vm_borrowed_from orelse parent;
        if (arch.boot.hhdmOffset()) |off| arch.pmap.destroy(child.pmap, off);
        child.pmap = parent.pmap;
        child.vm_borrowed_from = owner;
    } else {
        // A copy of the parent's map, its pages shared copy-on-write
        // (FreeBSD's vmspace_fork), so nothing is copied until one of the
        // two writes to a page.
        vm_map.forkCopy(&child.vm, child.pmap, kern_proc.vmOf(parent), parent.pmap) catch {
            kern_proc.free(child);
            return -1;
        };
    }

    // The child resumes from the same user frame, with the child's return
    // values: rax 0 and rdx 1. The carry flag must be cleared too:
    // FreeBSD's syscall stubs branch to their error path when it is set, so
    // inheriting the parent's carry from a previous failed syscall would
    // make the call look failed in the child.
    child_td.frame = frame.*;
    child_td.frame.rax = 0;
    child_td.frame.rdx = 1;
    child_td.frame.rflags &= ~@as(u64, 1);
    frame.rdx = 0;

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
    // The child's thread keeps the caller's thread pointer (TLS) until it
    // execs; without this, libc's per-thread state (errno, ...) faults on
    // the first access.
    child_td.fsbase = caller.fsbase;

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
        const caught: bool = parent.sig_handler[sg] != signal.SIG_DFL and parent.sig_handler[sg] != signal.SIG_IGN;
        if (options.drop_caught_signals and caught) {
            child.sig_handler[sg] = signal.SIG_DFL;
            child.sig_flags[sg] = 0;
            child.sig_actmask[sg] = 0;
        }
    }
    child.sig_pending = 0;
    // Timers are not inherited (POSIX); the nice value is.
    child.itimer_due = 0;
    child.itimer_interval = 0;
    child.nice = parent.nice;
    child_td.sig_mask = caller.sig_mask;
    // The alternate signal stack is inherited (FreeBSD's TDP_ALTSTACK).
    child_td.altstack = caller.altstack;
    // The caller's FPU state is live in the registers.
    arch.fpu.fpusave(&child_td.fpu);
    // The child joins the parent's process group and session.
    child.pgid = parent.pgid;
    child.sid = parent.sid;

    kern_sched.prepareContext(child_td);
    child.ppwait = options.ppwait;
    child_td.state = .runnable;

    // A vfork parent waits for the child to exec or exit (FreeBSD's
    // ast_vfork): until then the child uses its address space.
    while (child.ppwait) kern_sched.sleep(@ptrCast(&child.ppwait));
    return child.pid;
}

/// fork(2).
pub fn fork(frame: *arch.trapframe.TrapFrame) i32 {
    return fork1(frame, .{});
}

/// vfork(2): a child that borrows the parent's address space while the
/// parent waits.
pub fn vfork(frame: *arch.trapframe.TrapFrame) i32 {
    return fork1(frame, .{ .share_vm = true, .ppwait = true });
}

// rfork(2) flags (FreeBSD's sys/unistd.h).
const RFFDG: u64 = 1 << 2;
const RFPROC: u64 = 1 << 4;
const RFMEM: u64 = 1 << 5;
/// From user space this bit is RFSPAWN (the kernel's own RFPPWAIT shares it).
const RFSPAWN: u64 = 1 << 31;

/// rfork(2): `rfork(flags)`. RFSPAWN (alone) makes a posix_spawn child: a
/// vfork whose caught signals revert to their defaults. Otherwise a new
/// process (RFPROC) with a copy of the descriptor table (RFFDG), and the
/// parent's memory with RFMEM; the other rfork options are not supported,
/// and asking for them fails with EINVAL, as FreeBSD fails what it rejects
/// (which tells posix_spawn(3) to fall back to vfork).
pub fn rfork(frame: *arch.trapframe.TrapFrame, flags: u64) i32 {
    if ((flags & RFSPAWN) != 0) {
        if (flags != RFSPAWN) return -errno.EINVAL;
        return fork1(frame, .{ .share_vm = true, .ppwait = true, .drop_caught_signals = true });
    }
    if ((flags & ~(RFFDG | RFPROC | RFMEM)) != 0) return -errno.EINVAL;
    if ((flags & (RFPROC | RFFDG)) != (RFPROC | RFFDG)) return -errno.EINVAL;
    return fork1(frame, .{ .share_vm = (flags & RFMEM) != 0 });
}
