// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// brk and mmap.
//
// This is the Zig counterpart of NetBSD's sys/uvm/vm_mmap.c, reduced to brk:
// it grows or shrinks the process's heap by mapping or abandoning pages. Pages
// are mapped eagerly here; demand-zero faults will replace this once the region
// registry is per-process.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const proc: type = @import("../sys/proc.zig");
const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");
const vm_page: type = @import("vm_page.zig");
const kern_proc: type = @import("../kern/kern_proc.zig");
const kern_descrip: type = @import("../kern/kern_descrip.zig");
const prf: type = @import("../kern/subr_prf.zig");
const file: type = @import("../sys/file.zig");
const vnode: type = @import("../sys/vnode.zig");

/// mmap(2) flag bits (FreeBSD).
const MAP_ANON: u64 = 0x1000;

/// mmap(2) protection bits (FreeBSD).
const PROT_WRITE: u64 = 0x2;
const PROT_EXEC: u64 = 0x4;

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
            const pa: u64 = arch.pmap.allocPage(p.pmap) orelse return sys.signed(-errno.ENOMEM);
            arch.pmap.enterUser(p.pmap, va, pa, .user_rw);
        }
    }

    p.brk = addr;
    prf.log(prf.LOG_DEBUG, "brk: pid %d -> %x", .{ p.pid, p.brk });
    return p.brk;
}

/// mmap(2): map memory for the process. Supports anonymous memory and
/// read/copy mappings of a vnode-backed file (which is what rtld-elf uses to
/// read and load shared objects). `addr`, when non-zero, is honored as the
/// mapping address (rtld passes an explicit base). Returns the mapped address
/// or an error.
pub fn sysMmap(args: [sys.MAXARGS]u64) u64 {
    const addr: u64 = args[0];
    const len: u64 = args[1];
    const protbits: u64 = args[2];
    const flags: u64 = args[3];
    // FreeBSD's mmap takes an `int` fd; the caller may pass -1 zero-extended.
    const fd: i64 = @as(i32, @bitCast(@as(u32, @truncate(args[4]))));
    const offset: u64 = args[5];

    if (len == 0) {
        return sys.signed(-errno.ENOMEM);
    }
    const p: *proc.Proc = kern_proc.current;

    const limit: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE - param.PAGE_SIZE;
    const size: u64 = param.alignUp(len, param.PAGE_SIZE);

    var base: u64 = undefined;
    if (addr != 0) {
        base = addr & ~@as(u64, param.PAGE_SIZE - 1);
    } else {
        base = param.alignUp(p.mmap_next, param.PAGE_SIZE);
    }
    if (base + size > limit) {
        return sys.signed(-errno.ENOMEM);
    }

    var prot: arch.pmap.Prot = .user_ro;
    if ((protbits & PROT_EXEC) != 0) {
        prot = .user_rx;
    } else if ((protbits & PROT_WRITE) != 0) {
        prot = .user_rw;
    }

    const hhdm: u64 = arch.boot.hhdmOffset() orelse return sys.signed(-errno.ENOMEM);

    // A file mapping: resolve the open file to a vnode and copy its contents,
    // page by page, into fresh anonymous pages (private, copy semantics). A
    // device with an mmap hook (e.g. /dev/fb0) maps its own physical memory.
    const file_backed: bool = fd >= 0 and (flags & MAP_ANON) == 0;
    if (file_backed) {
        const f: *file.File = kern_descrip.fdGetfile(p, @intCast(fd)) orelse return sys.signed(-errno.EBADF);
        if (f.f_ops.mmap) |devmmap| {
            var va: u64 = base;
            var off: u64 = offset & ~@as(u64, param.PAGE_SIZE - 1);
            while (va < base + size) : ({
                va += param.PAGE_SIZE;
                off += param.PAGE_SIZE;
            }) {
                const pa: u64 = devmmap(f, off, @intCast(protbits)) orelse return sys.signed(-errno.ENXIO);
                arch.pmap.enterUser(p.pmap, va, pa, prot);
            }
        } else {
            if (f.f_type != file.DTYPE_VNODE) {
                return sys.signed(-errno.ENODEV);
            }
            const raw: ?*anyopaque = f.f_data orelse return sys.signed(-errno.EBADF);
            const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));

            var va: u64 = base;
            var foff: u64 = offset & ~@as(u64, param.PAGE_SIZE - 1);
            while (va < base + size) : ({
                va += param.PAGE_SIZE;
                foff += param.PAGE_SIZE;
            }) {
                const pa: u64 = arch.pmap.allocPage(p.pmap) orelse return sys.signed(-errno.ENOMEM);
                const dst: [*]u8 = @ptrFromInt(pa + hhdm);
                var k: usize = 0;
                while (k < param.PAGE_SIZE) : (k += 1) {
                    dst[k] = 0;
                }
                const n: isize = vp.v_op.read(vp, foff, dst[0..param.PAGE_SIZE]);
                if (n < 0) {
                    return sys.signed(-errno.EIO);
                }
                arch.pmap.enterUser(p.pmap, va, pa, prot);
            }
        }
    } else {
        var va: u64 = base;
        while (va < base + size) : (va += param.PAGE_SIZE) {
            const pa: u64 = arch.pmap.allocPage(p.pmap) orelse return sys.signed(-errno.ENOMEM);
            arch.pmap.enterUser(p.pmap, va, pa, prot);
        }
    }

    if (base + size > p.mmap_next) {
        p.mmap_next = base + size;
    }
    prf.log(prf.LOG_DEBUG, "mmap: pid %d at %x len %x", .{ p.pid, base, size });
    return base;
}

/// munmap(2): anonymous regions are left in place; just report success.
pub fn sysMunmap(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

/// mprotect(2): protection changes are not tracked yet; report success.
pub fn sysMprotect(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}
