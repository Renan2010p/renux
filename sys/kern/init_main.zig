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
const fbd: type = @import("../dev/fb/fb.zig");
const vnode: type = @import("../sys/vnode.zig");
const mount: type = @import("../sys/mount.zig");
const ext2fs: type = @import("../fs/ext2fs/ext2fs.zig");
const rootimage: type = @import("../fs/rootimage.zig");
const conf: type = @import("../sys/conf.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const kern_exec: type = @import("kern_exec.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const vfs_mount: type = @import("vfs_mount.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// Copyright notice (cf. FreeBSD's sys/conf/copyright).
const copyright: []const u8 =
    "Copyright (c) 2026 The Renux Project.  All rights reserved.\n\n";

/// Trademark notice (cf. FreeBSD's sys/conf/trademark).
const trademark: []const u8 =
    "Renux is a trademark of The Renux Project.\n\n";

/// Build identification, printed as "version machine" then the compiler line,
/// as FreeBSD's print_version() does: the release and config line, the build
/// path, then the compiler that produced the kernel.
const version: []const u8 =
    "Renux 0.1-RELEASE #0: Sat Oct 10 12:00:00 UTC 2026\n" ++
    "\tbuild@renux:/usr/obj/usr/src/amd64.amd64/sys/GENERIC amd64\n" ++
    "Renux clang version 22.1.8 (https://github.com/llvm/llvm-project.git) target: x86_64-unknown-renux\n";

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
    const r: ?rasops.Raster = bootRaster();
    arch.consinit.consinit(r);
    // Publish the framebuffer to userland as /dev/fb0 (FreeBSD's fbio.h ABI),
    // which is what a graphical server's scfb(4) driver mmaps and paints.
    if (r) |rr| {
        if (arch.boot.framebuffer(0)) |fb| {
            if (fb.address) |addr| {
                const hhdm: u64 = arch.boot.hhdmOffset() orelse 0;
                fbd.attach(rr, @intFromPtr(addr) - hhdm, fb.pitch * fb.height);
            }
        }
    }
}

/// Print the copyright notice.
fn announce(_: ?*const anyopaque) callconv(.c) void {
    // The loader-and-kernel hand-off line, as FreeBSD's loader prints it before
    // the kernel banner.
    prf.printLine("Loading kernel...");
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

/// Configure the system hardware: attach the legacy ISA devices and enable
/// interrupts (FreeBSD's SI_SUB_CONFIGURE). The device lines are printed in
/// FreeBSD's newbus dmesg format, `name<unit>: <description> ... on <parent>`
/// (sys/kern/subr_bus.c bus_print_child_header/footer), with the descriptions
/// FreeBSD's drivers use (sys/x86/isa/atpic.c, sys/x86/isa/atrtc.c,
/// sys/dev/atkbdc/atkbdc.c, sys/dev/uart/uart_bus_isa.c).
fn configure(_: ?*const anyopaque) callconv(.c) void {
    // CPU topology (sys/x86/x86/mp_x86.c cpu_mp_announce()), a single package
    // with one core and no hardware threads on this machine.
    prf.printLine("FreeBSD/SMP: 1 package(s) x 1 core(s)");
    prf.printLine("atpic0: <AT PIC> port 0x20-0x21,0xa0-0xa1 irq 0 on isa0");
    prf.printLine("atrtc0: <AT realtime clock> port 0x70-0x71 irq 8 on isa0");
    prf.printLine("atkbdc0: <Keyboard controller (i8042)> port 0x60,0x64 irq 1 on isa0");
    prf.printLine("atkbd0: <AT Keyboard> irq 1 on atkbdc0");
    prf.printLine("uart0: <16550 or compatible> port 0x3f8-0x3ff irq 4 flags 0x10 on isa0");
    if (arch.boot.framebuffer(0)) |fb| {
        prf.print("vt0: <Generic> resolution ");
        prf.printDec(fb.width);
        prf.print("x");
        prf.printDec(fb.height);
        prf.printLine(" on isa0");
    }
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
    prf.log(prf.LOG_INFO, "populate: %u boot modules", .{count});
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const mod: *arch.boot.File = arch.boot.module(i) orelse continue;
        const path_ptr: [*:0]const u8 = mod.path orelse continue;
        const address: ?*anyopaque = mod.address orelse continue;
        const path: []const u8 = cstr(path_ptr);
        const bytes: []const u8 = @as([*]const u8, @ptrCast(address))[0..@intCast(mod.size)];

        ensureParents(path);
        const vp: *vnode.Vnode = vfs_vnops.vn_create(path, .vreg, 0o755) orelse {
            prf.log(prf.LOG_WARNING, "populate: cannot create %s", .{path});
            continue;
        };
        _ = vp.v_op.write(vp, 0, bytes);
        vfs_subr.vrele(vp);
    }
}

/// Compare two byte strings for equality.
fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

/// Find the boot module whose path is `name`; returns its bytes, or null.
fn findModule(name: []const u8) ?[]const u8 {
    const count: usize = arch.boot.moduleCount() orelse 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const mod: *arch.boot.File = arch.boot.module(i) orelse continue;
        const path_ptr: [*:0]const u8 = mod.path orelse continue;
        const address: ?*anyopaque = mod.address orelse continue;
        if (strEq(cstr(path_ptr), name)) {
            return @as([*]const u8, @ptrCast(address))[0..@intCast(mod.size)];
        }
    }
    return null;
}

/// Populate the root tmpfs from a whole-filesystem image loaded as a single
/// boot module: walk the ext2fs tree and recreate every file, directory and
/// symbolic link. This gives the FreeBSD "live" layout (one image on the
/// medium instead of one boot module per file) while keeping a writable root.
fn unpackImage(image: []const u8) bool {
    var mnt: ext2fs.Ext2Mount = undefined;
    if (!ext2fs.mountInit(&mnt, image)) {
        return false;
    }
    // Show a spinner while the image is unpacked, as the loader does while it
    // loads the kernel and modules.
    prf.spinBegin("Loading configured modules... ");
    const copied: bool = copyDir(&mnt, ext2fs.ROOT_INO, &.{});
    prf.spinEnd();
    if (!copied) {
        return false;
    }
    const vp: *vnode.Vnode = vfs_lookup.nameiLookup("/sbin/init") orelse {
        prf.log(prf.LOG_WARNING, "unpack: /sbin/init missing", .{});
        return true;
    };
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
    _ = vp.v_op.getattr(vp, &vap);
    prf.log(prf.LOG_DEBUG, "/sbin/init size=%u", .{vap.size});
    return true;
}

/// Recursively copy the directory `ino` of `mnt` into `dir_path` in the root.
fn copyDir(mnt: *ext2fs.Ext2Mount, ino: u64, dir_path: []const u8) bool {
    const dir: ext2fs.Inode = ext2fs.readInode(mnt, ino) orelse return false;
    if ((dir.mode & ext2fs.S_IFMT) != ext2fs.S_IFDIR) {
        return false;
    }

    var pos: u64 = 0;
    var ent: ext2fs.DirEntry = undefined;
    while (ext2fs.dirNext(mnt, &dir, &pos, &ent)) {
        prf.spin();
        const name: []const u8 = ent.name[0..ent.name_len];
        if ((name.len == 1 and name[0] == '.') or
            (name.len == 2 and name[0] == '.' and name[1] == '.'))
        {
            continue;
        }

        // Build the child path: dir_path + "/" + name.
        var pathbuf: [param.MAXPATHLEN]u8 = undefined;
        var pl: usize = 0;
        if (dir_path.len == 0) {
            pathbuf[pl] = '/';
            pl += 1;
        } else {
            var d: usize = 0;
            while (d < dir_path.len and pl < pathbuf.len) : (d += 1) {
                pathbuf[pl] = dir_path[d];
                pl += 1;
            }
            if (pl > 0 and pathbuf[pl - 1] != '/') {
                pathbuf[pl] = '/';
                pl += 1;
            }
        }
        var n: usize = 0;
        while (n < name.len and pl < pathbuf.len) : (n += 1) {
            pathbuf[pl] = name[n];
            pl += 1;
        }
        const child: []const u8 = pathbuf[0..pl];

        const cin: ext2fs.Inode = ext2fs.readInode(mnt, ent.ino) orelse continue;
        const mode: u16 = cin.mode & 0o7777;
        switch (ext2fs.vtypeOf(cin.mode)) {
            .vdir => {
                ensureDir(child);
                _ = copyDir(mnt, ent.ino, child);
            },
            .vreg => {
                const vp: *vnode.Vnode = vfs_vnops.vn_create(child, .vreg, mode) orelse continue;
                var off: u64 = 0;
                var buf: [4096]u8 = undefined;
                while (off < cin.size) {
                    const got: usize = ext2fs.readData(mnt, &cin, off, &buf);
                    if (got == 0) {
                        break;
                    }
                    _ = vp.v_op.write(vp, off, buf[0..got]);
                    off += got;
                }
                vfs_subr.vrele(vp);
            },
            .vlnk => {
                var lbuf: [param.MAXPATHLEN]u8 = undefined;
                const ln: isize = ext2fs.readLink(mnt, &cin, &lbuf);
                if (ln > 0) {
                    const vp: *vnode.Vnode = vfs_vnops.vn_create(child, .vlnk, 0o777) orelse continue;
                    _ = vp.v_op.write(vp, 0, lbuf[0..@intCast(ln)]);
                    vfs_subr.vrele(vp);
                }
            },
            else => {}, // device nodes and specials: the kernel makes its own
        }
    }
    return true;
}

/// Mount a tmpfs as the system root.
fn mountTmpfs() ?*mount.Mount {
    prf.printLine("Trying to mount root from tmpfs []...");
    const mp: *mount.Mount = vfs_mount.mountFs("tmpfs", null) orelse {
        prf.log(prf.LOG_ERR, "cannot mount root filesystem", .{});
        return null;
    };
    vfs_mount.setRoot(mp);
    prf.log(prf.LOG_DEBUG, "tmpfs: mounted on /", .{});
    return mp;
}

/// Mount the system root: a tmpfs, populated from the whole-filesystem image
/// loaded as the /root.img module when present (so the medium carries one
/// filesystem image instead of one boot module per file), or from the
/// individual boot modules otherwise.
fn mountRoot() ?*mount.Mount {
    const mp: *mount.Mount = mountTmpfs() orelse return null;

    // FreeBSD's MD_ROOT: the root image is embedded in the kernel itself, so
    // the loader has to load nothing but the kernel.
    if (rootimage.bytes.len > 0) {
        prf.log(prf.LOG_INFO, "expanding the embedded root image (%u bytes)", .{rootimage.bytes.len});
        if (unpackImage(rootimage.bytes)) {
            return mp;
        }
        prf.log(prf.LOG_WARNING, "cannot expand the embedded root; trying modules", .{});
    }

    // Fall back to an image loaded as a boot module, then to per-file modules.
    if (findModule("/root.img")) |image| {
        prf.log(prf.LOG_INFO, "expanding /root.img (%u bytes) into the root", .{image.len});
        if (unpackImage(image)) {
            return mp;
        }
        prf.log(prf.LOG_WARNING, "cannot expand /root.img; using the modules", .{});
    }

    populateRoot();
    return mp;
}

/// Create directory `path` when it does not already exist.
fn ensureDir(path: []const u8) void {
    if (vfs_lookup.nameiLookup(path) != null) {
        return;
    }
    if (vfs_vnops.vn_create(path, .vdir, 0o755)) |vp| {
        vfs_subr.vrele(vp);
    }
}

/// Create the character-device node `path`.
fn mknod(path: []const u8, mode: u16, rdev: u64) void {
    if (vfs_vnops.vn_mknod(path, .vchr, mode, rdev)) |vp| {
        vfs_subr.vrele(vp);
    }
}

/// Create process 1 (init): mount the root filesystem, populate it from the
/// boot modules, load /sbin/init from it, set up its stack, and enter ring 3
/// (NetBSD's start_init()).
fn start_init(_: ?*const anyopaque) callconv(.c) void {
    _ = mountRoot() orelse return;

    // Device nodes (the root is a writable tmpfs).
    ensureDir("/dev");
    mknod("/dev/console", 0o600, conf.makedev(0, 0));
    mknod("/dev/tty", 0o666, conf.makedev(1, 0));
    // The virtual console ttyv0 (FreeBSD's init only starts a session on a tty
    // marked "onifexists" when the device node exists).
    mknod("/dev/ttyv0", 0o600, conf.makedev(0, 0));
    mknod("/dev/null", 0o666, conf.makedev(2, 2));
    mknod("/dev/zero", 0o666, conf.makedev(2, 12));
    mknod("/dev/fb0", 0o600, conf.makedev(fbd.FB_MAJOR, 0));

    ensureDir("/tmp");
    ensureDir("/var");
    ensureDir("/var/log");
    ensureDir("/var/run");
    ensureDir("/etc/rc.d");

    kern_proc.init();

    // Create the init process; alloc() gives it its own address space.
    const init = kern_proc.alloc() orelse {
        prf.log(prf.LOG_ERR, "cannot create init process", .{});
        return;
    };

    const result = kern_exec.loadInto(null, init.pmap, "/sbin/init", 0) orelse {
        prf.log(prf.LOG_ERR, "cannot load /sbin/init", .{});
        return;
    };

    // Map the initial user stack.
    var va: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE;
    while (va < arch.vmparam.USER_STACK_TOP) : (va += param.PAGE_SIZE) {
        const pa: u64 = vm_page.physalloc() orelse return;
        arch.pmap.enterUser(init.pmap, va, pa, .user_rw);
    }
    if (!kern_exec.mapTrampoline(init.pmap)) {
        prf.log(prf.LOG_ERR, "cannot map trampoline", .{});
        return;
    }

    // Build init's initial argument block: argv = ["/sbin/init"], envp has a
    // default TERM so full-screen programs (ncurses) can start on the console.
    const args: []const []const u8 = &.{"/sbin/init"};
    const env: []const []const u8 = &.{"TERM=xterm"};
    const info: kern_exec.StartInfo = kern_exec.buildStack(init.pmap, args, env, &.{}) orelse {
        prf.log(prf.LOG_ERR, "cannot build init stack", .{});
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
        prf.log(prf.LOG_ERR, "cannot set up initial TLS", .{});
        return;
    }

    kern_sched.prepareContext(init);
    init.state = .runnable;

    prf.log(prf.LOG_DEBUG, "init: starting at %x", .{result.entry});

    // From here on, output is userland: switch the console to the FreeBSD-like
    // normal (light grey) foreground, cursor included.
    cons.cnSetColor(0xc0, 0xc0, 0xc0);

    prf.log(prf.LOG_INFO, "sched: starting the scheduler (preemptive, PIT @ 100 Hz)", .{});
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
