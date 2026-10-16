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
const errno: type = @import("../sys/errno.zig");
const proc: type = @import("../sys/proc.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const signal: type = @import("../sys/signal.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const arch: type = @import("../arch/arch.zig");
const std: type = @import("std");
const kern_proc: type = @import("kern_proc.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// The most bytes execve() accepts for the arguments and the environment
/// together, their terminating NULs included (FreeBSD's ARG_MAX, also
/// reported by sysctl kern.argmax). There is no limit on their number.
pub const ARG_MAX: usize = 256 * 1024;

/// The arguments and environment of a program being started (FreeBSD's
/// struct image_args): the strings, each NUL-terminated, the arguments first
/// and then the environment, in one kernel buffer of ARG_MAX bytes. execve()
/// copies them here while the caller's address space is still current, and
/// buildStack() copies them onto the new program's stack.
pub const ImageArgs: type = struct {
    buf: []u8,
    /// Bytes of `buf` in use.
    len: usize = 0,
    argc: usize = 0,
    envc: usize = 0,

    pub const Error: type = error{
        /// The strings do not fit in ARG_MAX bytes.
        TooBig,
        /// No memory for the buffer.
        NoMemory,
    };

    const PAGES: u64 = ARG_MAX / param.PAGE_SIZE;

    /// An empty set of arguments, with its buffer.
    pub fn init() Error!ImageArgs {
        const pa: vm_page.PAddr = vm_page.physallocContig(PAGES) orelse return error.NoMemory;
        const hhdm: u64 = arch.boot.hhdmOffset() orelse return error.NoMemory;
        const first: [*]u8 = @ptrFromInt(pa.int() + hhdm);
        return .{ .buf = first[0..ARG_MAX] };
    }

    /// Give back the buffer.
    pub fn deinit(a: *ImageArgs) void {
        const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
        vm_page.physfreeContig(vm_page.PAddr.fromInt(@intFromPtr(a.buf.ptr) - hhdm), PAGES);
    }

    /// Append `str` (without its NUL).
    fn append(a: *ImageArgs, str: []const u8) Error!void {
        if (a.len + str.len + 1 > a.buf.len) return error.TooBig;
        @memcpy(a.buf[a.len..][0..str.len], str);
        a.buf[a.len + str.len] = 0;
        a.len += str.len + 1;
    }

    /// Append an argument. All the arguments come before the environment.
    pub fn addArg(a: *ImageArgs, str: []const u8) Error!void {
        std.debug.assert(a.envc == 0);
        try a.append(str);
        a.argc += 1;
    }

    /// Append an environment string.
    pub fn addEnv(a: *ImageArgs, str: []const u8) Error!void {
        try a.append(str);
        a.envc += 1;
    }

    /// Append the NUL-terminated strings of the caller's vector at user
    /// address `vec` (an argv or envp array, ended by a null pointer) as
    /// arguments (`env` false) or environment strings, starting with the
    /// `skip`-th.
    pub fn copyinVector(a: *ImageArgs, vec: u64, skip: usize, env: bool) Error!void {
        if (vec == 0) return;
        const pointers: [*]align(1) const u64 = @ptrFromInt(vec);
        var i: usize = 0;
        while (true) : (i += 1) {
            const str_addr: u64 = pointers[i];
            if (str_addr == 0) return;
            if (i < skip) continue;
            const str: []const u8 = cstrUser(str_addr, a.buf.len - a.len) orelse return error.TooBig;
            if (env) try a.addEnv(str) else try a.addArg(str);
        }
    }

    /// The strings, as stored: arguments then environment, each followed by
    /// its NUL.
    pub fn strings(a: *const ImageArgs) []const u8 {
        return a.buf[0..a.len];
    }

    /// Argument `index` (from 0), without its NUL.
    pub fn arg(a: *const ImageArgs, index: usize) []const u8 {
        var rest: []const u8 = a.strings();
        for (0..index) |_| rest = rest[std.mem.indexOfScalar(u8, rest, 0).? + 1 ..];
        return std.mem.sliceTo(rest, 0);
    }
};

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
    prf.log(prf.LOG_DEBUG, "exec: loading %s", .{path});
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
        const pa: u64 = arch.pmap.allocPage(pmap) orelse return false;
        arch.pmap.enterUser(pmap, va, pa, .user_rw);
    }
    return true;
}

/// Virtual address of the sigreturn trampoline, just below the user stack.
pub fn trampolineVa() u64 {
    return arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE - param.PAGE_SIZE;
}

/// Map the signal trampoline: a page holding the port's sigcode, where a
/// process resumes to run a signal handler and then call sigreturn(2).
pub fn mapTrampoline(pmap: arch.pmap.Pmap) bool {
    const pa: u64 = arch.pmap.allocPage(pmap) orelse return false;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;

    const stub = arch.exec_machdep.sigcode;
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

/// Write a byte string to `va` in `pmap`, a page at a time through the
/// pages' physical addresses.
fn putBytes(pmap: arch.pmap.Pmap, va: u64, src: []const u8) bool {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    var done: usize = 0;
    while (done < src.len) {
        const addr: u64 = va + done;
        const in_page: usize = @intCast(param.PAGE_SIZE - (addr % param.PAGE_SIZE));
        const n: usize = @min(in_page, src.len - done);
        const pa: u64 = arch.pmap.extract(pmap, addr) orelse return false;
        const dst: [*]u8 = @ptrFromInt(pa + hhdm);
        @memcpy(dst[0..n], src[done..][0..n]);
        done += n;
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

/// Build the initial stack in `pmap` for `args`: the strings at the top, then
/// below them argc, the argv and envp pointer vectors and the aux vector.
/// Returns where the process should start, or null on failure.
pub fn buildStack(pmap: arch.pmap.Pmap, args: *const ImageArgs, auxv: []const AuxPair) ?StartInfo {
    // The strings, as one block (arguments, then environment).
    const strings: []const u8 = args.strings();
    const strings_va: u64 = arch.vmparam.USER_STACK_TOP - strings.len;
    if (!putBytes(pmap, strings_va, strings)) return null;
    const sp: u64 = strings_va;
    const argc: usize = args.argc;
    const envc: usize = args.envc;
    // argc, then argv (NUL-terminated), then envp (NUL-terminated), then the
    // aux vector (pairs terminated by AT_NULL), then the page-size array that
    // AT_PAGESIZES points at.  AT_PAGESIZES and AT_PAGESIZESLEN are appended.
    const entries: u64 = 1 + @as(u64, argc + 1) + @as(u64, envc + 1) +
        @as(u64, (auxv.len + 2) * 2) + 2 + PAGESIZES_SLOTS;
    var base: u64 = sp - entries * 8;
    base &= ~@as(u64, 15); // 16-byte aligned
    base -= 8; // leave rsp so that rsp % 16 == 8 at entry, and argv 8-aligned

    if (!putU64(pmap, base, argc)) return null;
    var cursor: u64 = base + 8;

    // argv, its terminator, envp, its terminator: the address of each string
    // in the block, in order.
    var string_va: u64 = strings_va;
    var start: usize = 0;
    for (0..argc + envc) |index| {
        if (index == argc) {
            if (!putU64(pmap, cursor, 0)) return null; // argv terminator
            cursor += 8;
        }
        if (!putU64(pmap, cursor, string_va)) return null;
        cursor += 8;
        const end: usize = std.mem.indexOfScalarPos(u8, strings, start, 0).?;
        string_va += end + 1 - start;
        start = end + 1;
    }
    if (envc == 0) {
        if (!putU64(pmap, cursor, 0)) return null; // argv terminator
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
        .argc = argc,
        .argv = base + 8,
        .envp = base + 8 + (argc + 1) * 8,
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
        const pa: u64 = arch.pmap.allocPage(pmap) orelse return false;
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

/// Read a NUL-terminated string of at most `max` bytes (its NUL excluded)
/// from the current (old) address space; null when it is longer.
fn cstrUser(addr: u64, max: usize) ?[]const u8 {
    if (addr == 0) return null;
    const p: [*]const u8 = @ptrFromInt(addr);
    var len: usize = 0;
    while (len < max) : (len += 1) {
        if (p[len] == 0) return p[0..len];
    }
    return null;
}

/// Copy the caller's argument vector `argv_ptr` (from its `skip_args`-th
/// string) and environment vector `envp_ptr` into `args`.
fn copyinArgs(args: *ImageArgs, argv_ptr: u64, envp_ptr: u64, skip_args: usize) ImageArgs.Error!void {
    try args.copyinVector(argv_ptr, skip_args, false);
    try args.copyinVector(envp_ptr, 0, true);
}

/// The errno execve(2) reports for an ImageArgs error.
fn argsErrno(err: ImageArgs.Error) i32 {
    return switch (err) {
        error.TooBig => -errno.E2BIG,
        error.NoMemory => -errno.ENOMEM,
    };
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

/// Record the absolute path of the program `p` is about to run, for
/// sysctl kern.proc.pathname: `path` itself when it is absolute, else the
/// working directory joined with it (a leading "./" dropped). A path that
/// does not fit is left out (the process then reports none).
fn recordExePath(p: *proc.Proc, path: []const u8) void {
    var rel: []const u8 = path;
    while (rel.len > 2 and rel[0] == '.' and rel[1] == '/') rel = rel[2..];
    const prefix: []const u8 = if (path.len > 0 and path[0] == '/') "" else p.cwd_path[0..p.cwd_len];
    const separator: []const u8 = if (prefix.len > 0 and prefix[prefix.len - 1] != '/') "/" else "";
    const total: usize = prefix.len + separator.len + rel.len;
    if (total > p.exe_path.len) {
        p.exe_path_len = 0;
        return;
    }
    @memcpy(p.exe_path[0..prefix.len], prefix);
    @memcpy(p.exe_path[prefix.len..][0..separator.len], separator);
    @memcpy(p.exe_path[prefix.len + separator.len ..][0..rel.len], rel);
    p.exe_path_len = total;
}

/// Replace the current process's image with the program at `path`, started with
/// the argument vector `argv_ptr` and environment `envp_ptr` (pointers into the
/// caller's address space). A "#!" script runs its interpreter. On success the
/// caller returns to ring 3.
pub fn execve(frame: *arch.trapframe.TrapFrame, path: []const u8, argv_ptr: u64, envp_ptr: u64) i32 {
    // Copy the caller's arguments and environment while its address space
    // is still current (FreeBSD's exec_copyin_args).
    var args: ImageArgs = ImageArgs.init() catch return -errno.ENOMEM;
    defer args.deinit();
    copyinArgs(&args, argv_ptr, envp_ptr, 0) catch |err| return argsErrno(err);

    const p: *proc.Proc = kern_proc.current;

    // Resolve the target. A "#!" script runs its interpreter instead, with
    // the arguments FreeBSD gives it: the interpreter, its optional
    // argument, the script's path, then the script's own arguments after
    // argv[0].
    var exe_path: []const u8 = path;
    var script_buf: [param.MAXPATHLEN]u8 = undefined;
    var interp: []const u8 = undefined;
    var sarg: ?[]const u8 = null;
    var script_args: ?ImageArgs = null;
    defer if (script_args) |*a| a.deinit();
    {
        const vp: *vnode.Vnode = vfs_lookup.nameiAt(p.cwd, path) orelse return -errno.ENOENT;
        const is_script: bool = scriptInterp(vp, &script_buf, &interp, &sarg);
        vfs_subr.vrele(vp);
        if (is_script) {
            exe_path = interp;
            script_args = ImageArgs.init() catch return -errno.ENOMEM;
            const a: *ImageArgs = &script_args.?;
            a.addArg(interp) catch |err| return argsErrno(err);
            if (sarg) |extra| a.addArg(extra) catch |err| return argsErrno(err);
            a.addArg(path) catch |err| return argsErrno(err);
            copyinArgs(a, argv_ptr, envp_ptr, 1) catch |err| return argsErrno(err);
        }
    }
    const image_args: *const ImageArgs = if (script_args) |*a| a else &args;

    recordExePath(p, exe_path);

    // Record the program name (basename of the executable), for ps/top/htop.
    {
        var base: usize = 0;
        var j: usize = 0;
        while (j < exe_path.len) : (j += 1) {
            if (exe_path[j] == '/') {
                base = j + 1;
            }
        }
        const bn: []const u8 = exe_path[base..];
        const m: usize = if (bn.len > p.name.len) p.name.len else bn.len;
        var q: usize = 0;
        while (q < m) : (q += 1) {
            p.name[q] = bn[q];
        }
        p.name_len = m;
    }

    const newmap: arch.pmap.Pmap = arch.pmap.create() orelse return -errno.ENOMEM;
    const main: exec_elf.Result = loadInto(p.cwd, newmap, exe_path, 0) orelse return -errno.ENOEXEC;
    if (!mapStack(newmap)) {
        return -errno.ENOMEM;
    }
    if (!mapTrampoline(newmap)) {
        return -errno.ENOMEM;
    }

    // A PT_INTERP image is a dynamic executable: load the interpreter (the
    // dynamic linker) and enter it, passing the main program's details in the
    // aux vector.
    var entry: u64 = main.entry;
    var interp_base: u64 = 0;
    if (main.interp_len > 0) {
        const ipath: []const u8 = main.interp[0..main.interp_len];
        const interp_res: exec_elf.Result = loadInto(p.cwd, newmap, ipath, INTERP_BASE) orelse return -errno.ENOEXEC;
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

    const info: StartInfo = buildStack(newmap, image_args, auxv[0..an]) orelse return -errno.ENOMEM;

    p.brk = main.brk;
    p.mmap_next = param.USER_MMAP_BASE;
    p.inherit_zero = @splat(.{});
    p.anon = @splat(.{});
    if (!setupInitialTls(p, newmap, main)) {
        return -errno.ENOMEM;
    }

    // Caught signals revert to their default action across exec; ignored
    // ones stay ignored (POSIX).
    var sg: usize = 0;
    while (sg < signal.NSIG) : (sg += 1) {
        p.sig_flags[sg] = 0;
        p.sig_actmask[sg] = 0;
        if (p.sig_handler[sg] != signal.SIG_IGN) {
            p.sig_handler[sg] = signal.SIG_DFL;
        }
    }

    // The new image starts with a clean FPU (FreeBSD's fpstate_drop).
    p.fpu = arch.fpu.initial();
    arch.fpu.fpurestore(&p.fpu);

    // Descriptors marked close-on-exec do not survive the new image.
    kern_descrip.fdCloseOnExec(p);
    p.sig_pending = 0;

    const oldmap: arch.pmap.Pmap = p.pmap;
    arch.pmap.activate(newmap);
    p.pmap = newmap;
    // The old address space is no longer needed: free exactly the pages
    // recorded for it (its own tables and data; the shared kernel half was
    // never recorded, so it is untouched).
    if (oldmap != 0 and oldmap != newmap) {
        arch.pmap.destroy(oldmap, 0);
    }

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
