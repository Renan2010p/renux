// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// exec(): load an executable image.
//
// The Zig counterpart of NetBSD's sys/kern/kern_exec.c: the front end that
// dispatches to the right image activator (only ELF so far), plus execve(),
// which replaces the current process's image with a program named among the
// boot modules (there is no filesystem yet).

const exec_elf: type = @import("exec_elf.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");

/// Result of a successful image load.
pub const Result: type = struct {
    entry: u64,
};

/// Load `bytes` as a program image into page map `pmap`.
pub fn exec(pmap: arch.pmap.Pmap, bytes: []const u8) ?Result {
    if (!exec_elf.isElf(bytes)) {
        return null;
    }
    const loaded = exec_elf.load(pmap, bytes) orelse return null;
    return .{ .entry = loaded.entry };
}

fn cstr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn basenameMatches(path: []const u8, name: [*:0]const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            start = i + 1;
        }
    }
    const base = path[start..];
    var j: usize = 0;
    while (j < base.len and name[j] != 0) : (j += 1) {
        if (base[j] != name[j]) {
            return false;
        }
    }
    return j == base.len and name[j] == 0;
}

/// Find a boot module by the base name of its path.
pub fn findImage(name: [*:0]const u8) ?[]const u8 {
    const count: usize = arch.boot.moduleCount() orelse return null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const m = arch.boot.module(i) orelse continue;
        const path_ptr = m.path orelse continue;
        if (!basenameMatches(cstr(path_ptr), name)) {
            continue;
        }
        const address = m.address orelse continue;
        const bytes: [*]const u8 = @ptrCast(address);
        return bytes[0..@intCast(m.size)];
    }
    return null;
}

/// Replace the current process's image with the program named `name`. On
/// success the caller returns to ring 3 at the new entry point.
pub fn execve(frame: *arch.trapframe.TrapFrame, name: [*:0]const u8) i32 {
    const image: []const u8 = findImage(name) orelse return -1;
    const p = kern_proc.current;

    const newmap: arch.pmap.Pmap = arch.pmap.create() orelse return -1;
    const loaded = exec_elf.load(newmap, image) orelse return -1;

    // A fresh user stack for the new image.
    var va: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE;
    while (va < arch.vmparam.USER_STACK_TOP) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return -1;
        arch.pmap.enterUser(newmap, va, pa, .user_rw);
    }

    arch.pmap.activate(newmap);
    p.pmap = newmap;

    frame.rip = loaded.entry;
    frame.rsp = arch.vmparam.USER_STACK_TOP - 8;
    frame.rax = 0;
    return 0;
}
