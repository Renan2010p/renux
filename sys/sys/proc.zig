// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Process and kernel thread state.
//
// This is a simplified counterpart of NetBSD's sys/sys/proc.h and sys/sys/lwp.h,
// fused into one structure for now: a process owns an address space (its page
// map) and a kernel thread with a kernel stack and a saved user frame.

const arch: type = @import("../arch/arch.zig");
const param: type = @import("param.zig");
const signal: type = @import("signal.zig");
const file: type = @import("file.zig");
const vnode: type = @import("vnode.zig");

pub const Context: type = arch.proc_md.Context;
pub const TrapFrame: type = arch.trapframe.TrapFrame;

/// Size of the per-process open file table.
pub const NFILE: usize = 16;

/// Process state.
pub const State: type = enum(u8) {
    unused = 0,
    runnable,
    running,
    sleeping,
    zombie,
};

pub const Proc: type = struct {
    pid: i32,
    state: State,
    parent: ?*Proc,
    exit_status: i32,
    /// Physical address of the top-level page table (CR3 value).
    pmap: u64,
    /// Kernel stack: physical page (for freeing) and top virtual address.
    kstack_page: u64,
    kstack_top: u64,
    /// Kernel thread context for swtch().
    context: Context,
    /// User frame used when the process first enters ring 3.
    frame: TrapFrame,
    /// Sleep channel (see kern_sched.sleep/wakeup).
    chan: ?*anyopaque,
    /// Open file table (descriptors 0..NFILE-1).
    fds: [NFILE]?*file.File,
    /// Current working directory, or null before the root is mounted.
    cwd: ?*vnode.Vnode,
    /// Path of the current working directory (for getcwd).
    cwd_path: [param.MAXPATHLEN]u8,
    /// Length of cwd_path.
    cwd_len: usize,
    /// Current program break (end of the heap).
    brk: u64,
    /// Next address anonymous mmap() will hand out.
    mmap_next: u64,
    /// Real user id.
    uid: u32,
    /// Pending signal bits.
    sig_pending: u64,
    /// Blocked signal bits.
    sig_mask: u64,
    /// Handler per signal (SIG_DFL/SIG_IGN or a user address).
    sig_handler: [signal.NSIG]u64,
};
