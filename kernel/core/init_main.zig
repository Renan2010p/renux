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
const kern_syscall: type = @import("kern_syscall.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_sched: type = @import("kern_sched.zig");
const vfs_mount: type = @import("vfs_mount.zig");
const geom_disk: type = @import("../geom/geom_disk.zig");
const randomdev: type = @import("../dev/random/randomdev.zig");
const vfs_vnops: type = @import("vfs_vnops.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_subr: type = @import("vfs_subr.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");
const subr_clock: type = @import("subr_clock.zig");
const vers: type = @import("vers");
const builtin: type = @import("builtin");

/// Copyright notice (cf. FreeBSD's sys/conf/copyright).
const copyright: []const u8 =
    "Copyright (c) 2026 The Renux Project. All rights reserved.\n";

/// Trademark notice (cf. FreeBSD's sys/conf/trademark).
const trademark: []const u8 =
    "Renux is a trademark of The Renux Project.\n";

/// Machine name, as uname -m reports it (the port's <machine/param.h>).
const machine: []const u8 = arch.machine_param.MACHINE;

/// FreeBSD's boothowto: the boot flags (sys/sys/reboot.h).
pub var boothowto: u32 = 0;
pub const RB_SINGLE: u32 = 0x002; // -s: boot to single user
pub const RB_VERBOSE: u32 = 0x800; // -v: print all potentially useful info

/// The root the loader asked for ("ext2fs:/dev/vda2"), or null to use the
/// embedded boot image. Set from the command line (vfs.root.mountfrom=...).
var root_from: ?[]const u8 = null;

/// Parse the kernel arguments the loader passed: the FreeBSD boot flags (`-v`,
/// `-s`) and the loader variables that mean the same (`boot_verbose`,
/// `boot_single`, optionally `=YES`).
fn bootFlags(_: ?*const anyopaque) callconv(.c) void {
    const args: []const u8 = arch.boot.cmdline() orelse return;
    var i: usize = 0;
    while (i < args.len) {
        while (i < args.len and args[i] == ' ') : (i += 1) {}
        const start: usize = i;
        while (i < args.len and args[i] != ' ') : (i += 1) {}
        var word: []const u8 = args[start..i];
        if (word.len == 0) {
            continue;
        }
        if (word[0] == '-') {
            for (word[1..]) |c| {
                switch (c) {
                    'v' => boothowto |= RB_VERBOSE,
                    's' => boothowto |= RB_SINGLE,
                    else => {},
                }
            }
            continue;
        }
        if (strStarts(word, "boot_verbose")) {
            word = word["boot_verbose".len..];
            if (word.len == 0 or strEq(word, "=YES") or strEq(word, "=1")) {
                boothowto |= RB_VERBOSE;
            }
        } else if (strStarts(word, "boot_single")) {
            boothowto |= RB_SINGLE;
        } else if (strStarts(word, "truss=")) {
            kern_syscall.setTruss(word["truss=".len..]);
        } else if (strStarts(word, "vfs.root.mountfrom=")) {
            root_from = word["vfs.root.mountfrom=".len..];
        } else if (strStarts(word, "root=")) {
            root_from = word["root=".len..];
        } else if (strStarts(word, "console=")) {
            // The loader's console choice: comconsole, vidconsole, or both
            // (comma separated).
            // Values naming neither are ignored.
            const list: []const u8 = word["console=".len..];
            const video: bool = contains(list, "vidconsole");
            const serial: bool = contains(list, "comconsole");
            if (video or serial) {
                console_video = video;
                console_serial = serial;
            }
        }
    }
    prf.bootverbose = (boothowto & RB_VERBOSE) != 0;
}

/// Consoles to attach (the loader's `console` variable); both by default.
var console_video: bool = true;
var console_serial: bool = true;

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (strEq(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn strStarts(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and strEq(s[0..prefix.len], prefix);
}

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
    arch.consinit.consinit(if (console_video) r else null, console_serial);
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
    // A foreign loader (Limine) prints nothing of its own, so say what it did,
    // as FreeBSD's loader would; the Renux loader has already reported the
    // load. It belongs to the loader stage, so it goes to the console only and
    // dmesg(8) starts at the boot mark instead.
    if (!arch.boot.renuxLoader()) {
        prf.cnprint("Loading kernel...\n");
    }
    prf.msgbufBootMark();
    prf.print(copyright);
}

/// Print the trademark notice.
fn printTrademark(_: ?*const anyopaque) callconv(.c) void {
    prf.print(trademark);
}

/// Print the version and compiler identification exactly as FreeBSD's
/// print_version() prints the string newvers.sh made, then the machine:
///
/// a reproducible build (the default, like FreeBSD releases):
///   Renux 0.1-CURRENT main-n96-6627e9f4b9c7 GENERIC amd64
///
/// a developer build (zig build -Ddevbuild=true):
///   Renux 0.1-CURRENT #0 main-n96-6627e9f4b9c7: Tue Oct 13 01:02:03 UTC 2026
///       renan@host:/home/renan/renux/sys GENERIC amd64
///
/// followed by the compiler line.
fn printVersion(_: ?*const anyopaque) callconv(.c) void {
    if (vers.devbuild) {
        var buf: [subr_clock.TIME_LEN]u8 = undefined;
        prf.printf("Renux %s-%s #0 %s: %s\n    %s %s %s\n", .{
            vers.revision,                                vers.branch,  vers.source,
            subr_clock.formatTime(vers.build_time, &buf), vers.builder, vers.ident,
            machine,
        });
    } else {
        prf.printf("Renux %s-%s %s %s %s\n", .{ vers.revision, vers.branch, vers.source, vers.ident, machine });
    }
    prf.printf("Zig version %s (LLVM)\n", .{builtin.zig_version_string});
}

/// Report the virtual terminal's mode, FreeBSD's "VT(efifb): resolution WxH",
/// right after the version, where FreeBSD's vt(4) reports it.
fn printVt(_: ?*const anyopaque) callconv(.c) void {
    // The framebuffer came from UEFI GOP (efifb) under the Renux loader; a
    // foreign loader may have set a VBE mode, so name it generically then.
    if (!console_video) {
        return;
    }
    if (arch.boot.framebuffer(0)) |fb| {
        const name: []const u8 = if (arch.boot.renuxLoader()) "efifb" else "fb";
        prf.printf("VT(%s): resolution %ux%u\n", .{ name, fb.width, fb.height });
    }
}

/// Finish device configuration (FreeBSD's configure_final()): every driver
/// has attached and announced itself at SI_SUB_CONFIGURE (see
/// core/subr_bus.zig), so interrupts can be enabled.
fn configure_final(_: ?*const anyopaque) callconv(.c) void {
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
    prf.spinBegin("Unpacking the root image... ");
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

/// Mount a tmpfs as the system root, reporting it the way FreeBSD's
/// vfs_mountroot does: "Trying to mount root from <fs>:<device> [<opts>]...".
fn mountTmpfs(from: []const u8) ?*mount.Mount {
    prf.printf("Trying to mount root from tmpfs:%s []...\n", .{from});
    const mp: *mount.Mount = vfs_mount.mountFs("tmpfs", null) orelse {
        prf.printLine("Mounting from tmpfs failed: cannot allocate the file system.");
        return null;
    };
    vfs_mount.setRoot(mp);
    return mp;
}

/// Mount the root the loader named on the command line ("ext2fs:/dev/vda2",
/// or just the device). Returns null when the device or filesystem cannot be
/// used, so the caller falls back to the boot image.
fn mountDiskRoot(spec: []const u8) ?*mount.Mount {
    var fstype: []const u8 = "ext2fs";
    var dev: []const u8 = spec;
    var i: usize = 0;
    while (i < spec.len) : (i += 1) {
        if (spec[i] == ':') {
            fstype = spec[0..i];
            dev = spec[i + 1 ..];
            break;
        }
    }
    if (strStarts(dev, "/dev/")) dev = dev["/dev/".len..];
    if (dev.len == 0) return null;

    const dp: *geom_disk.Disk = geom_disk.byName(dev) orelse {
        prf.printf("Root device %s not found\n", .{dev});
        return null;
    };
    prf.printf("Trying to mount root from %s:%s []...\n", .{ fstype, dev });
    var args: ext2fs.Args = .{ .disk = dp, .readonly = false };
    return vfs_mount.mountRootFs(fstype, &args) orelse {
        prf.printLine("Mounting the root from disk failed.");
        return null;
    };
}

/// Mount the system root: a tmpfs, populated from the root image. The image is
/// embedded in the kernel (FreeBSD's MD_ROOT) or, failing that, loaded as the
/// /root.img module; either is announced as md0 like FreeBSD's md(4) does.
/// Without an image the root is populated from the individual boot modules.
/// When the loader named a root device (vfs.root.mountfrom=), it is tried
/// first -- that is how an installed system boots from its disk.
fn mountRoot() ?*mount.Mount {
    if (root_from) |spec| {
        if (mountDiskRoot(spec)) |mp| return mp;
        prf.printLine("WARNING: cannot mount the root on disk; using the boot image");
    }

    var root: ?*mount.Mount = null;

    if (rootimage.bytes.len > 0) {
        prf.printf("md0: Embedded image %u bytes at %p\n", .{ rootimage.bytes.len, rootimage.bytes.ptr });
        root = mountTmpfs("/dev/md0") orelse return null;
        if (unpackImage(rootimage.bytes)) {
            return root;
        }
        prf.printLine("WARNING: cannot expand the embedded root image; trying modules");
    }

    if (findModule("/root.img")) |image| {
        prf.printf("md0: Preloaded image </root.img> %u bytes at %p\n", .{ image.len, image.ptr });
        if (root == null) {
            root = mountTmpfs("/dev/md0") orelse return null;
        }
        if (unpackImage(image)) {
            return root;
        }
        prf.printLine("WARNING: cannot expand /root.img; using the boot modules");
    }

    if (root == null) {
        root = mountTmpfs("modules") orelse return null;
    }
    populateRoot();
    return root;
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
    mknod("/dev/random", 0o644, conf.makedev(randomdev.RANDOM_MAJOR, 0));
    mknod("/dev/urandom", 0o644, conf.makedev(randomdev.RANDOM_MAJOR, 0));
    // Disks, as FreeBSD's devfs names them (/dev/vtbd0, ...), owned by
    // root and group operator, 0640.
    for (geom_disk.list(), 0..) |dp, i| {
        var path: [32]u8 = undefined;
        const prefix: []const u8 = "/dev/";
        @memcpy(path[0..prefix.len], prefix);
        const name: []const u8 = geom_disk.devName(dp, path[prefix.len..]);
        mknod(path[0 .. prefix.len + name.len], 0o640, geom_disk.devOf(i));
    }

    ensureDir("/tmp");
    ensureDir("/var");
    ensureDir("/var/log");
    ensureDir("/var/run");

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
        const pa: u64 = (vm_page.physalloc() orelse return).int();
        arch.pmap.enterUser(init.pmap, va, pa, .user_rw);
    }
    if (!kern_exec.mapTrampoline(init.pmap)) {
        prf.log(prf.LOG_ERR, "cannot map trampoline", .{});
        return;
    }

    // Build init's initial argument block: argv = ["/sbin/init"], envp has a
    // default TERM so full-screen programs (ncurses) can start on the console.
    // As FreeBSD's start_init(), pass the single-user flag on to init.
    const args: []const []const u8 = if ((boothowto & RB_SINGLE) != 0)
        &.{ "/sbin/init", "-s" }
    else
        &.{"/sbin/init"};
    const env: []const []const u8 = &.{"TERM=xterm"};
    var image_args: kern_exec.ImageArgs = kern_exec.ImageArgs.init() catch {
        prf.log(prf.LOG_ERR, "cannot build init stack", .{});
        return;
    };
    defer image_args.deinit();
    for (args) |a| image_args.addArg(a) catch unreachable; // a few bytes
    for (env) |e| image_args.addEnv(e) catch unreachable;
    const info: kern_exec.StartInfo = kern_exec.buildStack(init.pmap, &image_args, &.{}) orelse {
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
    sysinit.SYSINIT("sysinit_bootflags", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FIRST, bootFlags, null);
    sysinit.SYSINIT("sysinit_console", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_SECOND, consinit, null);
    sysinit.SYSINIT("sysinit_announce", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_THIRD, announce, null);
    sysinit.SYSINIT("sysinit_trademark", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FOURTH, printTrademark, null);
    sysinit.SYSINIT("sysinit_version", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FIFTH, printVersion, null);
    sysinit.SYSINIT("sysinit_vt", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_MIDDLE, printVt, null);
    sysinit.SYSINIT("sysinit_configure", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_ANY, configure_final, null);
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
