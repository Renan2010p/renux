// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// exec(): load an executable image.
//
// The Zig counterpart of NetBSD's sys/kern/kern_exec.c: the front end that
// resolves a program's path through the VFS, hands the resulting vnode to the
// ELF image activator as a loader Source, and — for execve() — installs the
// freshly loaded image in the calling process and returns to ring 3 at its
// entry point.

const exec_elf: type = @import("exec_elf.zig");
const vnode: type = @import("../sys/vnode.zig");
const proc: type = @import("../sys/proc.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");

/// Read from a vnode, for the ELF loader.
fn vnodeRead(ctx: *anyopaque, offset: u64, buf: []u8) usize {
    const vp: *vnode.Vnode = @ptrCast(@alignCast(ctx));
    const n: isize = vp.v_op.read(vp, offset, buf);
    if (n <= 0) {
        return 0;
    }
    return @intCast(n);
}

/// Load the program at `path` into page map `pmap`. Returns null when the path
/// cannot be resolved, opened or interpreted.
pub fn loadInto(pmap: arch.pmap.Pmap, path: []const u8) ?exec_elf.Result {
    const vp: *vnode.Vnode = vfs_lookup.nameiLookup(path) orelse return null;

    var vap: vnode.Vattr = .{
        .type = .vnone,
        .mode = 0,
        .nlink = 0,
        .size = 0,
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    var size: u64 = 0;
    if (vp.v_op.getattr(vp, &vap) == 0) {
        size = vap.size;
    }

    const src: exec_elf.Source = .{ .ctx = vp, .size = size, .read = vnodeRead };
    const result: ?exec_elf.Result = exec_elf.load(pmap, src);
    vfs_subr.vrele(vp);
    return result;
}

/// Map a fresh user stack in `pmap`.
fn mapStack(pmap: arch.pmap.Pmap) bool {
    var va: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE;
    while (va < arch.vmparam.USER_STACK_TOP) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return false;
        arch.pmap.enterUser(pmap, va, pa, .user_rw);
    }
    return true;
}

/// Replace the current process's image with the program at `path`. On success
/// the caller returns to ring 3 at the new entry point.
pub fn execve(frame: *arch.trapframe.TrapFrame, path: []const u8) i32 {
    const p: *proc.Proc = kern_proc.current;

    const newmap: arch.pmap.Pmap = arch.pmap.create() orelse return -1;
    const loaded: exec_elf.Result = loadInto(newmap, path) orelse return -1;
    if (!mapStack(newmap)) {
        return -1;
    }

    arch.pmap.activate(newmap);
    p.pmap = newmap;

    frame.rip = loaded.entry;
    frame.rsp = arch.vmparam.USER_STACK_TOP - 8;
    frame.rax = 0;
    return 0;
}
