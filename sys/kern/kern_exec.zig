// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// exec(): load an executable image.
//
// The Zig counterpart of NetBSD's sys/kern/kern_exec.c: the front end that
// resolves a program's path through the VFS, hands the resulting vnode to the
// ELF image activator as a loader Source, and — for execve() — builds the new
// process's initial stack (argc/argv/envp) and installs the freshly loaded
// image, returning to ring 3 at its entry point.
//
// The kernel passes argc, argv and envp in the first three argument registers,
// so startup code does not have to guess where the stack begins; the stack is
// still laid out the traditional way so getenv(3) and friends can find it.

const exec_elf: type = @import("exec_elf.zig");
const vnode: type = @import("../sys/vnode.zig");
const proc: type = @import("../sys/proc.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");

/// Maximum number of arguments or environment strings execve() accepts.
pub const MAXARG: usize = 32;

/// Where the new process's stack and argument block live, once built.
pub const StartInfo: type = struct {
    /// Initial stack pointer (points at argc).
    rsp: u64,
    /// Number of arguments.
    argc: u64,
    /// Address of the argv vector.
    argv: u64,
    /// Address of the envp vector.
    envp: u64,
};

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

/// Write one byte to `va` in `pmap`, through the page's physical address.
fn putU8(pmap: arch.pmap.Pmap, va: u64, value: u8) bool {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    const pa: u64 = arch.pmap.extract(pmap, va) orelse return false;
    const dst: *u8 = @ptrFromInt(pa + hhdm);
    dst.* = value;
    return true;
}

/// Write a byte string to `va` in `pmap`.
fn putBytes(pmap: arch.pmap.Pmap, va: u64, src: []const u8) bool {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (!putU8(pmap, va + i, src[i])) {
            return false;
        }
    }
    return true;
}

/// Write a little-endian 64-bit word to `va` in `pmap`.
fn putU64(pmap: arch.pmap.Pmap, va: u64, value: u64) bool {
    var bytes: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        bytes[i] = @truncate(value >> @intCast(i * 8));
    }
    return putBytes(pmap, va, &bytes);
}

/// Build the initial stack in `pmap` for `argv`/`envp`: the strings first, from
/// the top down, then the pointer vectors and argc below them. Returns where
/// the process should start, or null on failure.
pub fn buildStack(pmap: arch.pmap.Pmap, argv: []const []const u8, envp: []const []const u8) ?StartInfo {
    if (argv.len > MAXARG or envp.len > MAXARG) {
        return null;
    }

    var sp: u64 = arch.vmparam.USER_STACK_TOP;

    // Copy the strings, highest argument first, so they read top-down.
    var argv_va: [MAXARG]u64 = undefined;
    var i: usize = argv.len;
    while (i > 0) {
        i -= 1;
        const s: []const u8 = argv[i];
        sp -= s.len + 1;
        if (!putBytes(pmap, sp, s)) return null;
        if (!putU8(pmap, sp + s.len, 0)) return null;
        argv_va[i] = sp;
    }

    var envp_va: [MAXARG]u64 = undefined;
    i = envp.len;
    while (i > 0) {
        i -= 1;
        const s: []const u8 = envp[i];
        sp -= s.len + 1;
        if (!putBytes(pmap, sp, s)) return null;
        if (!putU8(pmap, sp + s.len, 0)) return null;
        envp_va[i] = sp;
    }

    // argc, then argv (NUL-terminated), then envp (NUL-terminated).
    const entries: u64 = 1 + @as(u64, argv.len + 1) + @as(u64, envp.len + 1);
    var base: u64 = sp - entries * 8;
    base &= ~@as(u64, 15); // 16-byte aligned
    base -= 8; // leave rsp so that rsp % 16 == 8 at entry, and argv 8-aligned

    if (!putU64(pmap, base, argv.len)) return null; // argc
    var cursor: u64 = base + 8;

    var j: usize = 0;
    while (j < argv.len) : (j += 1) {
        if (!putU64(pmap, cursor, argv_va[j])) return null;
        cursor += 8;
    }
    if (!putU64(pmap, cursor, 0)) return null; // argv terminator
    cursor += 8;

    j = 0;
    while (j < envp.len) : (j += 1) {
        if (!putU64(pmap, cursor, envp_va[j])) return null;
        cursor += 8;
    }
    if (!putU64(pmap, cursor, 0)) return null; // envp terminator

    return .{
        .rsp = base,
        .argc = argv.len,
        .argv = base + 8,
        .envp = base + 8 + (argv.len + 1) * 8,
    };
}

/// Read a NUL-terminated string from the current (old) address space.
fn cstrUser(addr: u64) ?[]const u8 {
    if (addr == 0) {
        return null;
    }
    const p: [*]const u8 = @ptrFromInt(addr);
    var len: usize = 0;
    while (len < param.MAXPATHLEN * 16) : (len += 1) {
        if (p[len] == 0) {
            return p[0..len];
        }
    }
    return null;
}

/// Read a user argv/envp vector (an array of string pointers) into `out`.
fn readVec(vec: u64, out: *[MAXARG][]const u8) ?usize {
    if (vec == 0) {
        return 0;
    }
    const p: [*]const u64 = @ptrFromInt(vec);
    var n: usize = 0;
    while (n < MAXARG) : (n += 1) {
        const s: u64 = p[n];
        if (s == 0) {
            break;
        }
        out[n] = cstrUser(s) orelse return null;
    }
    return n;
}

/// Replace the current process's image with the program at `path`, started with
/// the argument vector `argv_ptr` and environment `envp_ptr` (pointers into the
/// caller's address space). On success the caller returns to ring 3.
pub fn execve(frame: *arch.trapframe.TrapFrame, path: []const u8, argv_ptr: u64, envp_ptr: u64) i32 {
    // Read the caller's arguments while its address space is still current.
    var argbuf: [MAXARG][]const u8 = undefined;
    var envbuf: [MAXARG][]const u8 = undefined;
    const argc: usize = readVec(argv_ptr, &argbuf) orelse return -1;
    const envc: usize = readVec(envp_ptr, &envbuf) orelse return -1;

    const p: *proc.Proc = kern_proc.current;

    const newmap: arch.pmap.Pmap = arch.pmap.create() orelse return -1;
    const loaded: exec_elf.Result = loadInto(newmap, path) orelse return -1;
    if (!mapStack(newmap)) {
        return -1;
    }
    const info: StartInfo = buildStack(newmap, argbuf[0..argc], envbuf[0..envc]) orelse return -1;

    arch.pmap.activate(newmap);
    p.pmap = newmap;

    frame.rip = loaded.entry;
    frame.rsp = info.rsp;
    frame.rdi = info.argc;
    frame.rsi = info.argv;
    frame.rdx = info.envp;
    frame.rax = 0;
    return 0;
}
