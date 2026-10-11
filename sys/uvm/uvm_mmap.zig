// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// brk and mmap.
//
// This is the Zig counterpart of NetBSD's sys/uvm/uvm_mmap.c, reduced to brk:
// it grows or shrinks the process's heap by mapping or abandoning pages. Pages
// are mapped eagerly here; demand-zero faults will replace this once the region
// registry is per-process.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const proc: type = @import("../sys/proc.zig");
const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");
const uvm_page: type = @import("uvm_page.zig");
const kern_proc: type = @import("../kern/kern_proc.zig");

/// brk(2): set the program break; returns the new break or an error. The heap
/// grows from just after the loaded image up to just below the signal
/// trampoline.
pub fn sysBrk(args: [sys.MAXARGS]u64) u64 {
    const addr: u64 = args[0];
    const p: *proc.Proc = kern_proc.current;

    // A zero argument queries the current break without changing it.
    if (addr == 0) {
        return p.brk;
    }

    const limit: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE - param.PAGE_SIZE;
    if (addr >= limit) {
        return sys.signed(-errno.ENOMEM);
    }

    if (addr > p.brk) {
        var va: u64 = param.alignUp(p.brk, param.PAGE_SIZE);
        const end: u64 = param.alignUp(addr, param.PAGE_SIZE);
        while (va < end) : (va += param.PAGE_SIZE) {
            const pa: u64 = uvm_page.physalloc() orelse return sys.signed(-errno.ENOMEM);
            arch.pmap.enterUser(p.pmap, va, pa, .user_rw);
        }
    }

    p.brk = addr;
    return p.brk;
}

/// mmap(2): map anonymous memory. Only the anonymous case is implemented:
/// `addr`, `fd` and `offset` are ignored and the region is placed at the next
/// free address. Returns the mapped address or an error.
pub fn sysMmap(args: [sys.MAXARGS]u64) u64 {
    const len: u64 = args[1];
    if (len == 0) {
        return sys.signed(-errno.ENOMEM);
    }
    const p: *proc.Proc = kern_proc.current;

    const limit: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE - param.PAGE_SIZE;
    const size: u64 = param.alignUp(len, param.PAGE_SIZE);
    const base: u64 = param.alignUp(p.mmap_next, param.PAGE_SIZE);
    if (base + size > limit) {
        return sys.signed(-errno.ENOMEM);
    }

    var va: u64 = base;
    while (va < base + size) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return sys.signed(-errno.ENOMEM);
        arch.pmap.enterUser(p.pmap, va, pa, .user_rw);
    }
    p.mmap_next = base + size;
    return base;
}

/// munmap(2): anonymous regions are left in place; just report success.
pub fn sysMunmap(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}
