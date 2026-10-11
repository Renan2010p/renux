// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Kernel main: system startup.
//
// This follows FreeBSD's model: instead of a hand-ordered sequence of calls,
// subsystems register initializers with SYSINIT at a (subsystem, order)
// priority, and mi_startup() sorts and runs them. main() therefore reduces to
// "run the registered initializers, then idle". The copyright/trademark/version
// announcement and the console and init bring-up are registered here, in the
// same spirit as FreeBSD's sys/kern/init_main.c.

const arch: type = @import("../arch/arch.zig");
const rasops: type = @import("../dev/rasops/rasops.zig");
const cons: type = @import("../dev/cons.zig");
const vnode: type = @import("../sys/vnode.zig");
const conf: type = @import("../sys/conf.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const kern_exec: type = @import("kern_exec.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const vfs_mount: type = @import("vfs_mount.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// Copyright notice (cf. FreeBSD's sys/conf/copyright).
const copyright: []const u8 =
    "Copyright (c) 2026 The Renux Project.  All rights reserved.\n\n";

/// Trademark notice (cf. FreeBSD's sys/conf/trademark).
const trademark: []const u8 =
    "Renux is a trademark of The Renux Project.\n\n";

/// Build identification, printed as "version machine" then the compiler line,
/// as FreeBSD's print_version() does.
const version: []const u8 =
    "Renux 0.1 (GENERIC) #0: Sat Oct 10 12:00:00 UTC 2026\n" ++
    "\tbuild@renux:/usr/src/sys/amd64/compile/GENERIC amd64\n" ++
    "Renux clang version 22.1.8 (https://github.com/llvm/llvm-project.git)\n";

/// Build a machine-independent raster from the boot framebuffer.
fn bootRaster() ?rasops.Raster {
    const fb = arch.boot.framebuffer(0) orelse return null;
    const address = fb.address orelse return null;
    return .{
        .base = @ptrCast(address),
        .width = @intCast(fb.width),
        .height = @intCast(fb.height),
        .stride = @intCast(fb.pitch),
        .depth = @intCast(fb.bpp),
        .red_mask_size = fb.red_mask_size,
        .red_mask_shift = fb.red_mask_shift,
        .green_mask_size = fb.green_mask_size,
        .green_mask_shift = fb.green_mask_shift,
        .blue_mask_size = fb.blue_mask_size,
        .blue_mask_shift = fb.blue_mask_shift,
    };
}

/// Find and initialise the console, for early messages (NetBSD's consinit()).
fn consinit(_: ?*const anyopaque) callconv(.c) void {
    arch.consinit.consinit(bootRaster());
}

/// Print the copyright notice.
fn announce(_: ?*const anyopaque) callconv(.c) void {
    prf.print(copyright);
}

/// Print the trademark notice.
fn printTrademark(_: ?*const anyopaque) callconv(.c) void {
    prf.print(trademark);
}

/// Print the version and compiler identification.
fn printVersion(_: ?*const anyopaque) callconv(.c) void {
    prf.print(version);
}

/// Configure the system hardware. This enables interrupts (FreeBSD's
/// SI_SUB_CONFIGURE; NetBSD's configure()).
fn configure(_: ?*const anyopaque) callconv(.c) void {
    prf.printLine("isa0 at mainbus0");
    prf.printLine("i8259: legacy PIC, master at 0x20 slave at 0xa0");
    prf.printLine("apic: not present, using the legacy PIC");
    prf.printLine("com0 at isa0 port 0x3f8-0x3ff irq 4: ns16550a, 16-byte fifo");
    prf.printLine("attimer0 at isa0 port 0x40-0x43");
    if (arch.boot.framebuffer(0)) |fb| {
        prf.print("wsdisplay0 at mainbus0: console (");
        prf.printDec(fb.width);
        prf.print("x");
        prf.printDec(fb.height);
        prf.print(", ");
        prf.printDec(fb.bpp);
        prf.printLine("bpp)");
    }
    prf.printLine("Timecounter \"i8254\" frequency 1193182 Hz quality 0");
    prf.printLine("syscall: fast system call (syscall/sysret) enabled");
    prf.printLine("Renux: enabling interrupts (PIT @ 100 Hz)");
    arch.cpu.enable_interrupts();
}

/// A NUL-terminated kernel string as a slice.
fn cstr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

/// Ensure that every parent directory of `path` exists in the root filesystem.
fn ensureParents(path: []const u8) void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') {
            continue;
        }
        const dir: []const u8 = path[0..i];
        if (vfs_lookup.nameiLookup(dir)) |vp| {
            vfs_subr.vrele(vp);
            continue;
        }
        if (vfs_vnops.vn_create(dir, .vdir, 0o755)) |vp| {
            vfs_subr.vrele(vp);
        }
    }
}

/// Populate the root filesystem from the boot modules: each module's path
/// becomes a file, so /sbin/init and /bin/sh are ordinary files and no longer
/// special cases. Parent directories are created as needed.
fn populateRoot() void {
    const count: usize = arch.boot.moduleCount() orelse 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const mod: *arch.boot.File = arch.boot.module(i) orelse continue;
        const path_ptr: [*:0]const u8 = mod.path orelse continue;
        const address: ?*anyopaque = mod.address orelse continue;
        const path: []const u8 = cstr(path_ptr);
        const bytes: []const u8 = @as([*]const u8, @ptrCast(address))[0..@intCast(mod.size)];

        ensureParents(path);
        const vp: *vnode.Vnode = vfs_vnops.vn_create(path, .vreg, 0o755) orelse continue;
        _ = vp.v_op.write(vp, 0, bytes);
        vfs_subr.vrele(vp);
    }
}

/// Create process 1 (init): mount the root filesystem, populate it from the
/// boot modules, load /sbin/init from it, set up its stack, and enter ring 3
/// (NetBSD's start_init()).
fn start_init(_: ?*const anyopaque) callconv(.c) void {
    prf.printLine("Trying to mount root from tmpfs []...");
    const mp = vfs_mount.mountFs("tmpfs", null) orelse {
        prf.printLine("init: cannot mount root filesystem");
        return;
    };
    vfs_mount.setRoot(mp);
    prf.printLine("tmpfs: mounted on /");
    populateRoot();

    // Create /dev and its console device node.
    if (vfs_lookup.nameiLookup("/dev") == null) {
        if (vfs_vnops.vn_create("/dev", .vdir, 0o755)) |vp| {
            vfs_subr.vrele(vp);
        }
    }
    if (vfs_vnops.vn_mknod("/dev/console", .vchr, 0o600, conf.makedev(0, 0))) |vp| {
        vfs_subr.vrele(vp);
    }
    if (vfs_vnops.vn_mknod("/dev/tty", .vchr, 0o666, conf.makedev(1, 0))) |vp| {
        vfs_subr.vrele(vp);
    }

    // /var/log, for the system log.
    if (vfs_lookup.nameiLookup("/var") == null) {
        if (vfs_vnops.vn_create("/var", .vdir, 0o755)) |vp| {
            vfs_subr.vrele(vp);
        }
    }
    if (vfs_lookup.nameiLookup("/var/log") == null) {
        if (vfs_vnops.vn_create("/var/log", .vdir, 0o755)) |vp| {
            vfs_subr.vrele(vp);
        }
    }
    if (vfs_lookup.nameiLookup("/etc/rc.d") == null) {
        if (vfs_vnops.vn_create("/etc/rc.d", .vdir, 0o755)) |vp| {
            vfs_subr.vrele(vp);
        }
    }

    kern_proc.init();

    // Create the init process; alloc() gives it its own address space.
    const init = kern_proc.alloc() orelse {
        prf.printLine("init: cannot create process");
        return;
    };

    const result = kern_exec.loadInto(null, init.pmap, "/sbin/init", 0) orelse {
        prf.printLine("init: cannot load /sbin/init");
        return;
    };

    // Map the initial user stack.
    var va: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE;
    while (va < arch.vmparam.USER_STACK_TOP) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return;
        arch.pmap.enterUser(init.pmap, va, pa, .user_rw);
    }
    if (!kern_exec.mapTrampoline(init.pmap)) {
        prf.printLine("init: cannot map trampoline");
        return;
    }

    // Build init's initial argument block: argv = ["/sbin/init"], envp has a
    // default TERM so full-screen programs (ncurses) can start on the console.
    const args: []const []const u8 = &.{"/sbin/init"};
    const env: []const []const u8 = &.{"TERM=xterm"};
    const info: kern_exec.StartInfo = kern_exec.buildStack(init.pmap, args, env, &.{}) orelse {
        prf.printLine("init: cannot build stack");
        return;
    };

    // Build the user frame init starts with. The SysV ABI expects rsp % 16 == 8
    // at function entry, so bias the stack by 8.
    init.frame.r15 = 0;
    init.frame.r14 = 0;
    init.frame.r13 = 0;
    init.frame.r12 = 0;
    init.frame.r11 = 0;
    init.frame.r10 = 0;
    init.frame.r9 = 0;
    init.frame.r8 = 0;
    init.frame.rdi = info.rsp; // FreeBSD entry: %rdi points at argc
    init.frame.rsi = 0;
    init.frame.rbp = 0;
    init.frame.rbx = 0;
    init.frame.rdx = 0;
    init.frame.rcx = 0;
    init.frame.rax = 0;
    init.frame.vector = 0;
    init.frame.error_code = 0;
    init.frame.rip = result.entry;
    init.frame.cs = arch.gdt_defs.UCODE_SEL;
    init.frame.rflags = 0x202; // reserved bit + IF
    init.frame.rsp = info.rsp;
    init.frame.ss = arch.gdt_defs.UDATA_SEL;

    // The process starts with the root as its working directory.
    init.cwd = vfs_mount.getRoot();
    if (init.cwd) |cwd| {
        vfs_subr.vref(cwd);
    }
    init.cwd_path[0] = '/';
    init.cwd_len = 1;
    init.brk = result.brk;
    init.mmap_next = param.USER_MMAP_BASE;
    if (!kern_exec.setupInitialTls(init, init.pmap, result)) {
        prf.printLine("init: cannot set up initial TLS");
        return;
    }

    kern_sched.prepareContext(init);
    init.state = .runnable;

    prf.print("init: starting at ");
    prf.printHex(result.entry);
    prf.printLine("");

    // From here on, output is userland: switch the console to the FreeBSD-like
    // normal (light grey) foreground, cursor included.
    cons.cnSetColor(0xc0, 0xc0, 0xc0);

    prf.printLine("sched: starting the scheduler (preemptive, PIT @ 100 Hz)");
    // Run the scheduler; it never returns.
    kern_sched.scheduler();
}

comptime {
    sysinit.SYSINIT("sysinit_console", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FIRST, consinit, null);
    sysinit.SYSINIT("sysinit_announce", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_SECOND, announce, null);
    sysinit.SYSINIT("sysinit_trademark", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_THIRD, printTrademark, null);
    sysinit.SYSINIT("sysinit_version", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FOURTH, printVersion, null);
    sysinit.SYSINIT("sysinit_configure", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_MIDDLE, configure, null);
    sysinit.SYSINIT("sysinit_start_init", sysinit.SI_SUB_LAST, sysinit.SI_ORDER_FIRST, start_init, null);
}

/// Run every registered initializer, in (subsystem, order) order
/// (FreeBSD's mi_startup()).
pub fn mi_startup() void {
    const list: []sysinit.Sysinit = sysinit.entries();
    sysinit.sort(list);
    for (list) |*entry| {
        entry.func(entry.udata);
    }
}

/// System startup; run the registered initializers.
pub export fn main() void {
    mi_startup();

    // Should not get here; the scheduler is an infinite loop in NetBSD/FreeBSD.
    while (true) {
        arch.cpu.idle();
    }
}
