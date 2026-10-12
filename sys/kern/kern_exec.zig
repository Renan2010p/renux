// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
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
const signal: type = @import("../sys/signal.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("kern_proc.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// Maximum number of arguments or environment strings execve() accepts.
pub const MAXARG: usize = 32;

/// Base address at which a PT_INTERP interpreter (a dynamic linker) is mapped.
const INTERP_BASE: u64 = 0x0000_0000_2000_0000;

/// One aux-vector entry.
pub const AuxPair: type = struct {
    type: u64,
    val: u64,
};

// Aux-vector types (ELF).
const AT_PHDR: u64 = 3;
const AT_PHENT: u64 = 4;
const AT_PHNUM: u64 = 5;
const AT_PAGESZ: u64 = 6;
const AT_BASE: u64 = 7;
const AT_ENTRY: u64 = 9;
const AT_UID: u64 = 11;
const AT_EUID: u64 = 12;
const AT_GID: u64 = 13;
const AT_EGID: u64 = 14;
const AT_PAGESIZES: u64 = 20;
const AT_PAGESIZESLEN: u64 = 21;

/// Number of u64 slots for the page-size array handed to AT_PAGESIZES.  Must be
/// at least MAXPAGESIZES (3 on amd64); AT_PAGESIZESLEN is its size in bytes.
const PAGESIZES_SLOTS: u64 = 8;

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

/// Load the program at `path` (relative to `start`, or absolute) into page map
/// `pmap`, at link address + `base`. Returns null when the path cannot be
/// resolved, opened or interpreted.
pub fn loadInto(start: ?*vnode.Vnode, pmap: arch.pmap.Pmap, path: []const u8, base: u64) ?exec_elf.Result {
    const vp: *vnode.Vnode = vfs_lookup.nameiAt(start, path) orelse return null;

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
    const result: ?exec_elf.Result = exec_elf.load(pmap, src, base);
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

/// Virtual address of the sigreturn trampoline, just below the user stack.
pub fn trampolineVa() u64 {
    return arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE - param.PAGE_SIZE;
}

/// Map the sigreturn trampoline: a page whose first bytes execute the
/// sigreturn system call, used as the return address of a signal handler.
pub fn mapTrampoline(pmap: arch.pmap.Pmap) bool {
    const pa: u64 = uvm_page.physalloc() orelse return false;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;

    // mov eax, SYS_sigreturn (417); int 0x80
    const stub: [7]u8 = .{ 0xb8, 0xa1, 0x01, 0x00, 0x00, 0xcd, 0x80 };
    const dst: [*]u8 = @ptrFromInt(pa + hhdm);
    var i: usize = 0;
    while (i < stub.len) : (i += 1) {
        dst[i] = stub[i];
    }
    arch.pmap.enterUser(pmap, trampolineVa(), pa, .user_rx);
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
pub fn buildStack(pmap: arch.pmap.Pmap, argv: []const []const u8, envp: []const []const u8, auxv: []const AuxPair) ?StartInfo {
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

    // argc, then argv (NUL-terminated), then envp (NUL-terminated), then the
    // aux vector (pairs terminated by AT_NULL), then the page-size array that
    // AT_PAGESIZES points at.  AT_PAGESIZES and AT_PAGESIZESLEN are appended.
    const entries: u64 = 1 + @as(u64, argv.len + 1) + @as(u64, envp.len + 1) +
        @as(u64, (auxv.len + 2) * 2) + 2 + PAGESIZES_SLOTS;
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
    cursor += 8;

    // FreeBSD's Elf_Auxinfo is { a_type; a_un; }: a 4-byte type first (padded
    // to 8), then the value.  Both rtld-elf and libc read it this way.
    for (auxv) |pair| {
        if (!putU64(pmap, cursor, pair.type)) return null;
        cursor += 8;
        if (!putU64(pmap, cursor, pair.val)) return null;
        cursor += 8;
    }
    // AT_PAGESIZES points at the page-size array in the last slots;
    // AT_PAGESIZESLEN is its length in bytes.  FreeBSD's libc (getpagesizes)
    // reads them.
    const pagesizes_va: u64 = base + (entries - PAGESIZES_SLOTS) * 8;
    if (!putU64(pmap, cursor, AT_PAGESIZES)) return null;
    cursor += 8;
    if (!putU64(pmap, cursor, pagesizes_va)) return null;
    cursor += 8;
    if (!putU64(pmap, cursor, AT_PAGESIZESLEN)) return null;
    cursor += 8;
    if (!putU64(pmap, cursor, PAGESIZES_SLOTS * 8)) return null;
    cursor += 8;
    if (!putU64(pmap, cursor, 0)) return null; // AT_NULL type
    cursor += 8;
    if (!putU64(pmap, cursor, 0)) return null; // AT_NULL value
    cursor += 8;
    var ps: u64 = 0;
    while (ps < PAGESIZES_SLOTS) : (ps += 1) {
        const v: u64 = if (ps == 0) param.PAGE_SIZE else 0;
        if (!putU64(pmap, cursor, v)) return null;
        cursor += 8;
    }

    return .{
        .rsp = base,
        .argc = argv.len,
        .argv = base + 8,
        .envp = base + 8 + (argv.len + 1) * 8,
    };
}

/// Size and alignment of a FreeBSD/amd64 TCB (struct tcb: a self pointer and a
/// pointer to the dynamic thread vector).
const TLS_TCB_SIZE: u64 = 16;
const TLS_TCB_ALIGN: u64 = 16;

/// Build the initial thread-local storage for `p` from the main image's PT_TLS
/// and install it as the thread pointer (IA32_FS_BASE). The FreeBSD amd64
/// kernel does the same, so a statically linked FreeBSD libc can bootstrap:
/// its own TLS allocator runs (and reads thread-local state) before it installs
/// the final TCB. With no PT_TLS the thread pointer is left at zero.
pub fn setupInitialTls(p: *proc.Proc, pmap: arch.pmap.Pmap, main: exec_elf.Result) bool {
    if (main.tls_memsz == 0) {
        p.fsbase = 0;
        return true;
    }
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;

    const alignment: u64 = if (main.tls_align > TLS_TCB_ALIGN) main.tls_align else TLS_TCB_ALIGN;
    const tls_space: u64 = param.alignUp(main.tls_memsz, alignment);
    const size: u64 = param.alignUp(tls_space + TLS_TCB_SIZE, param.PAGE_SIZE);
    const base: u64 = param.alignUp(p.mmap_next, param.PAGE_SIZE);

    var va: u64 = base;
    while (va < base + size) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return false;
        arch.pmap.enterUser(pmap, va, pa, .user_rw);
    }

    // Copy the initialised part of the TLS template; the rest stays zero.
    var i: u64 = 0;
    while (i < main.tls_filesz) : (i += 1) {
        const srcpa: u64 = arch.pmap.extract(pmap, main.tls_vaddr + i) orelse return false;
        const dstpa: u64 = arch.pmap.extract(pmap, base + i) orelse return false;
        const byte: u8 = @as(*const u8, @ptrFromInt(srcpa + hhdm)).*;
        @as(*u8, @ptrFromInt(dstpa + hhdm)).* = byte;
    }

    // The thread pointer sits just past the TLS data; the TCB is {self, dtv}.
    const tp: u64 = base + tls_space;
    const selfpa: u64 = arch.pmap.extract(pmap, tp) orelse return false;
    @as(*u64, @ptrFromInt(selfpa + hhdm)).* = tp;
    const dtvpa: u64 = arch.pmap.extract(pmap, tp + 8) orelse return false;
    @as(*u64, @ptrFromInt(dtvpa + hhdm)).* = 0;

    p.fsbase = tp;
    p.mmap_next = base + size;
    return true;
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

/// Read the first line of `vp`; when it is a "#! " line, point `interp` and
/// `arg` at the interpreter and its optional argument (slices of `buf`) and
/// return true.
fn scriptInterp(vp: *vnode.Vnode, buf: []u8, interp: *[]const u8, arg: *?[]const u8) bool {
    const n: isize = vp.v_op.read(vp, 0, buf);
    if (n < 2) {
        return false;
    }
    const len: usize = @intCast(n);
    if (buf[0] != '#' or buf[1] != '!') {
        return false;
    }

    var i: usize = 2;
    while (i < len and (buf[i] == ' ' or buf[i] == '\t')) : (i += 1) {}
    const istart: usize = i;
    while (i < len and buf[i] != ' ' and buf[i] != '\t' and buf[i] != '\n') : (i += 1) {}
    interp.* = buf[istart..i];

    while (i < len and (buf[i] == ' ' or buf[i] == '\t')) : (i += 1) {}
    if (i < len and buf[i] != '\n') {
        const astart: usize = i;
        while (i < len and buf[i] != ' ' and buf[i] != '\t' and buf[i] != '\n') : (i += 1) {}
        arg.* = buf[astart..i];
    } else {
        arg.* = null;
    }
    return interp.*.len > 0;
}

/// Replace the current process's image with the program at `path`, started with
/// the argument vector `argv_ptr` and environment `envp_ptr` (pointers into the
/// caller's address space). A "#!" script runs its interpreter. On success the
/// caller returns to ring 3.
pub fn execve(frame: *arch.trapframe.TrapFrame, path: []const u8, argv_ptr: u64, envp_ptr: u64) i32 {
    // Read the caller's arguments while its address space is still current.
    var argbuf: [MAXARG][]const u8 = undefined;
    var envbuf: [MAXARG][]const u8 = undefined;
    const argc: usize = readVec(argv_ptr, &argbuf) orelse return -1;
    const envc: usize = readVec(envp_ptr, &envbuf) orelse return -1;

    const p: *proc.Proc = kern_proc.current;

    // Resolve the target, following a #! interpreter.
    var exe_path: []const u8 = path;
    var final: [MAXARG][]const u8 = undefined;
    var final_argc: usize = argc;
    var k: usize = 0;
    while (k < argc) : (k += 1) {
        final[k] = argbuf[k];
    }

    var script_buf: [param.MAXPATHLEN]u8 = undefined;
    var interp: []const u8 = undefined;
    var sarg: ?[]const u8 = null;
    {
        const vp: *vnode.Vnode = vfs_lookup.nameiAt(p.cwd, path) orelse return -1;
        const is_script: bool = scriptInterp(vp, &script_buf, &interp, &sarg);
        vfs_subr.vrele(vp);
        if (is_script) {
            exe_path = interp;
            var tmp: [MAXARG][]const u8 = undefined;
            var n: usize = 0;
            tmp[n] = interp;
            n += 1;
            if (sarg) |a| {
                tmp[n] = a;
                n += 1;
            }
            tmp[n] = path; // argv[0] for the interpreter is the script
            n += 1;
            var j: usize = 1;
            while (j < argc and n < MAXARG) : (j += 1) {
                tmp[n] = argbuf[j];
                n += 1;
            }
            final = tmp;
            final_argc = n;
        }
    }

    const newmap: arch.pmap.Pmap = arch.pmap.create() orelse return -1;
    const main: exec_elf.Result = loadInto(p.cwd, newmap, exe_path, 0) orelse return -1;
    if (!mapStack(newmap)) {
        return -1;
    }
    if (!mapTrampoline(newmap)) {
        return -1;
    }

    // A PT_INTERP image is a dynamic executable: load the interpreter (the
    // dynamic linker) and enter it, passing the main program's details in the
    // aux vector.
    var entry: u64 = main.entry;
    var interp_base: u64 = 0;
    if (main.interp_len > 0) {
        const ipath: []const u8 = main.interp[0..main.interp_len];
        const interp_res: exec_elf.Result = loadInto(p.cwd, newmap, ipath, INTERP_BASE) orelse return -1;
        entry = interp_res.entry;
        interp_base = INTERP_BASE;
    }

    var auxv: [12]AuxPair = undefined;
    var an: usize = 0;
    auxv[an] = .{ .type = AT_PAGESZ, .val = param.PAGE_SIZE };
    an += 1;
    auxv[an] = .{ .type = AT_PHDR, .val = main.phdr };
    an += 1;
    auxv[an] = .{ .type = AT_PHENT, .val = main.phentsize };
    an += 1;
    auxv[an] = .{ .type = AT_PHNUM, .val = main.phnum };
    an += 1;
    auxv[an] = .{ .type = AT_ENTRY, .val = main.entry };
    an += 1;
    auxv[an] = .{ .type = AT_BASE, .val = interp_base };
    an += 1;
    auxv[an] = .{ .type = AT_UID, .val = p.uid };
    an += 1;
    auxv[an] = .{ .type = AT_EUID, .val = p.uid };
    an += 1;
    auxv[an] = .{ .type = AT_GID, .val = p.uid };
    an += 1;
    auxv[an] = .{ .type = AT_EGID, .val = p.uid };
    an += 1;

    const info: StartInfo = buildStack(newmap, final[0..final_argc], envbuf[0..envc], auxv[0..an]) orelse return -1;

    p.brk = main.brk;
    p.mmap_next = param.USER_MMAP_BASE;
    if (!setupInitialTls(p, newmap, main)) {
        return -1;
    }

    // Caught signals revert to their default action across exec.
    var sg: usize = 0;
    while (sg < signal.NSIG) : (sg += 1) {
        p.sig_handler[sg] = signal.SIG_DFL;
    }
    p.sig_pending = 0;

    const oldmap: arch.pmap.Pmap = p.pmap;
    arch.pmap.activate(newmap);
    p.pmap = newmap;
    // The pre-exec address space is freed when the process exits; tearing it
    // down here (while still returning through the old kernel context) is not
    // safe yet.
    _ = oldmap;

    frame.rip = entry;
    frame.rsp = info.rsp;
    // FreeBSD process-entry convention: %rdi points at argc on the initial
    // stack (both crt1 and the interpreter's rtld_start read it from there).
    // %rsi carries the cleanup/rtld_fini pointer (none here) and %rdx is
    // unused; the program derives argv and envp from the stack.
    frame.rdi = info.rsp;
    frame.rsi = 0;
    frame.rdx = 0;
    frame.rax = 0;
    return 0;
}
