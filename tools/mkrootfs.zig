// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// mkrootfs -- build the root file system image the kernel embeds.
//
// Usage: mkrootfs <userland> <image>
//
// The kernel carries its root file system (FreeBSD's MD_ROOT). This program
// makes that image in two stages:
//
//   1. stage the system into a directory tree, next to <image>:
//        - the native userland, as `zig build` installs it (<userland>:
//          bin/, sbin/, usr/bin/, ...), and /etc/fstab;
//        - when `zig build fetch` has downloaded it, the FreeBSD userland:
//          the programs listed below, every shared library they need
//          (found from each ELF file's DT_NEEDED entries, recursively), the
//          PAM modules and the configuration the login path reads;
//   2. pack the tree into an ext2 image with tools/mkfs.zig.
//
// The image is byte-for-byte reproducible (fixed timestamps, a zero UUID),
// so an unchanged system does not rebuild the kernel that embeds it.
//
// Paths are relative to the repository root, the build's working directory.

const std: type = @import("std");
const Io: type = std.Io;
const Dir: type = Io.Dir;
const Allocator: type = std.mem.Allocator;
const elf: type = std.elf;
const mkfs: type = @import("mkfs");

/// The FreeBSD base system and packages, as `zig build fetch` unpacks them.
const FREEBSD_BASE: []const u8 = "tools/freebsd/root";
const FREEBSD_PACKAGES: []const u8 = "tools/freebsd/pkgroot";
/// Renux's own /etc files.
const RENUX_ETC: []const u8 = "userland/etc";

/// The directories every root has, even when nothing is installed in them.
const SKELETON: []const []const u8 = &.{
    "boot",     "sbin",    "bin",   "usr/bin", "usr/sbin", "usr/libexec",
    "etc",      "lib",     "libexec", "dev",   "tmp",      "var",
    "var/log",  "var/run", "mnt",   "home",
};

/// FreeBSD programs installed when the base system is present, by their path
/// in the FreeBSD tree: the console login (getty, login with PAM, sh), the
/// everyday utilities, and the system tools Renux supports.
const FREEBSD_PROGRAMS: []const []const u8 = &.{
    "usr/libexec/getty", "usr/bin/login",
    "bin/sh",            "bin/ls",        "bin/cat",       "bin/echo",      "bin/pwd",        "bin/mkdir",
    "bin/rm",            "bin/rmdir",     "bin/cp",        "bin/mv",        "bin/ln",         "bin/chmod",
    "bin/date",          "bin/hostname",  "bin/sleep",     "bin/test",      "bin/expr",       "bin/kill",
    "bin/stty",          "bin/realpath",  "usr/bin/uname", "usr/bin/id",    "usr/bin/whoami", "usr/bin/env",
    "usr/bin/wc",        "usr/bin/head",  "usr/bin/tail",  "usr/bin/grep",  "usr/bin/sed",    "usr/bin/awk",
    "usr/bin/more",      "usr/bin/less",  "usr/bin/vi",    "usr/bin/clear", "usr/bin/tput",   "usr/bin/touch",
    "usr/bin/find",      "usr/bin/sort",  "usr/bin/uniq",  "usr/bin/tr",    "usr/bin/cut",    "usr/bin/basename",
    "usr/bin/dirname",   "usr/bin/true",  "usr/bin/false", "usr/bin/yes",   "usr/bin/printf", "usr/bin/which",
    "usr/bin/stat",      "usr/bin/du",    "usr/bin/tee",   "usr/bin/xargs", "usr/bin/logname", "usr/bin/tty",
    "usr/bin/uptime",    "usr/bin/w",     "usr/bin/who",   "usr/bin/hexdump", "usr/bin/fortune", "usr/bin/resizewin",
    "usr/bin/ee",        "usr/bin/dialog", "usr/bin/bsddialog",
    "usr/sbin/pwd_mkdb", "sbin/ldconfig",
    "sbin/mount",        "sbin/umount",   "bin/df",        "bin/sync",      "bin/dd",         "usr/bin/truncate",
    "sbin/md5",          "sbin/reboot",   "sbin/halt",     "sbin/poweroff", "sbin/shutdown",  "usr/bin/wall",
};

/// Programs from FreeBSD packages, installed when they have been fetched.
const PACKAGE_PROGRAMS: []const []const u8 = &.{ "usr/local/bin/bash", "usr/local/bin/nano" };

/// The PAM modules the login service stack loads (etc/pam.d/login, system).
const PAM_MODULES: []const []const u8 = &.{
    "pam_self", "pam_unix",    "pam_securetty", "pam_nologin", "pam_login_access",
    "pam_lastlog", "pam_xdg", "pam_permit",    "pam_deny",
};

/// Where FreeBSD's run-time linker looks for shared libraries.
const LIBRARY_DIRS: []const []const u8 = &.{ "lib", "usr/lib", "usr/local/lib" };

/// FreeBSD's /etc files the login path reads: accounts and their databases,
/// login classes, the getty table, name service switch, shells, profiles.
/// The accounts are FreeBSD's defaults: root has no password, as on a fresh
/// FreeBSD install.
const FREEBSD_ETC: []const []const u8 = &.{
    "gettytab",   "passwd",    "master.passwd", "pwd.db",        "spwd.db", "group", "login.conf",
    "login.conf.db", "login.access", "nsswitch.conf", "shells", "profile", "ttys",
};
const FREEBSD_PAM_SERVICES: []const []const u8 = &.{ "login", "system", "other", "passwd", "su" };
const FREEBSD_ROOT_DOTFILES: []const []const u8 = &.{ ".profile", ".shrc", ".cshrc", ".login" };

/// FreeBSD's base xterm entries (xterm, xterm-256color, ...) inherit from
/// "xterm-new", which has no smcup/rmcup: full-screen programs (nano, htop,
/// vi) cannot switch to the alternate screen and leave their drawing behind
/// on exit. It also lacks E3, the "erase the scrollback" capability clear(1)
/// uses. This entry, put first in the termcap file, shadows xterm-new with the
/// same capabilities plus those, so every xterm-derived TERM gets them.
const XTERM_NEW_ENTRY: []const u8 =
    "xterm-new|modern xterm:\\\n" ++
    "\t:E3=\\E[3J:te=\\E[?1049l:ti=\\E[?1049h:tc=xterm-basic:\n";

/// The ext2 layout of the image: 1 KiB blocks, 256-byte inodes (they hold
/// timestamps past 2038), nothing reserved, one inode per 4 KiB.
const IMAGE_FORMAT: mkfs.Options = .{
    .bs = 1024,
    .inode_size = 256,
    .reserved_pct = 0,
    .bytes_per_inode = 4096,
};

/// The image is the staged size plus half again plus 8 MiB of free space,
/// so the running system can write to its root.
fn imageBlocks(used_kib: u64) u64 {
    return used_kib + used_kib / 2 + 8192;
}

pub fn main(init: std.process.Init) !void {
    const io: Io = init.io;
    const arena: Allocator = init.arena.allocator();
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (args.len != 3) std.process.fatal("usage: mkrootfs <userland> <image>", .{});
    const userland_path: []const u8 = args[1];
    const image_path: []const u8 = args[2];

    const cwd: Dir = Dir.cwd();
    const work_path: []const u8 = try std.fs.path.join(arena, &.{ std.fs.path.dirname(image_path) orelse ".", "rootfs" });

    var userland: Dir = cwd.openDir(io, userland_path, .{ .iterate = true }) catch
        std.process.fatal("mkrootfs: cannot open the native userland {s} (run 'zig build userland')", .{userland_path});
    defer userland.close(io);
    if (!exists(io, userland, "sbin/init")) {
        std.process.fatal("mkrootfs: no native userland in {s} (run 'zig build userland')", .{userland_path});
    }

    // -- the staging tree ----------------------------------------------------
    try cwd.deleteTree(io, work_path);
    try cwd.createDirPath(io, work_path);
    var work: Dir = try cwd.openDir(io, work_path, .{ .iterate = true });
    defer work.close(io);
    for (SKELETON) |path| try work.createDirPath(io, path);

    // The native userland, at its system paths. The native shell also stays
    // available as /bin/renux-sh (a FreeBSD sh replaces /bin/sh), and the
    // native editor also answers to "edit".
    try copyTree(io, userland, work);
    try Dir.copyFile(work, "bin/sh", work, "bin/renux-sh", io, .{});
    try Dir.copyFile(work, "bin/nano", work, "bin/edit", io, .{});
    try Dir.copyFile(cwd, RENUX_ETC ++ "/fstab", work, "etc/fstab", io, .{});

    if (cwd.openDir(io, FREEBSD_BASE, .{ .iterate = true })) |base| {
        var freebsd: FreeBsd = .{
            .io = io,
            .arena = arena,
            .base = base,
            .packages = cwd.openDir(io, FREEBSD_PACKAGES, .{}) catch null,
            .work = work,
        };
        try freebsd.install();
    } else |_| {}

    // -- the image -----------------------------------------------------------
    const used_kib: u64 = try diskUsageKib(io, work);
    const tmp_path: []const u8 = try std.fmt.allocPrint(arena, "{s}.img", .{work_path});
    cwd.deleteFile(io, tmp_path) catch {};
    var options: mkfs.Options = IMAGE_FORMAT;
    options.dir = work_path;
    options.image = tmp_path;
    options.blocks = imageBlocks(used_kib);
    try mkfs.makeFs(io, std.heap.page_allocator, options);
    try Dir.rename(cwd, tmp_path, cwd, image_path, io);
}

// -- the FreeBSD userland ------------------------------------------------------

/// Installs FreeBSD's files into the staging tree. Renux runs FreeBSD's own
/// programs (FreeBSD/amd64 ABI), so the console login is FreeBSD's: getty(8),
/// login(1) with PAM, and sh(1), plus the everyday base utilities.
const FreeBsd: type = struct {
    io: Io,
    arena: Allocator,
    /// The base system, and the packages (null when not fetched).
    base: Dir,
    packages: ?Dir,
    work: Dir,
    /// Paths installed so far, so each file (and its libraries) is copied once.
    installed: std.StringHashMapUnmanaged(void) = .empty,

    fn install(f: *FreeBsd) !void {
        try f.installFile("libexec/ld-elf.so.1");
        for (FREEBSD_PROGRAMS) |path| try f.installFile(path);
        for (PACKAGE_PROGRAMS) |path| {
            if (f.packages != null and exists(f.io, f.packages.?, path)) try f.installFile(path);
        }
        for (PAM_MODULES) |module| {
            const library: []const u8 = try std.fmt.allocPrint(f.arena, "{s}.so.6", .{module});
            try f.installFile(try std.fmt.allocPrint(f.arena, "usr/lib/{s}", .{library}));
            try f.symlink(library, try std.fmt.allocPrint(f.arena, "usr/lib/{s}.so", .{module}));
        }
        // /bin/test also answers to [.
        try f.symlink("test", "bin/[");

        try f.preferFreeBsdCommands();
        try f.installConfiguration();
    }

    /// The tree a FreeBSD file comes from: the base system, else the packages.
    fn source(f: *const FreeBsd, path: []const u8) ?Dir {
        if (exists(f.io, f.base, path)) return f.base;
        if (f.packages) |packages| {
            if (exists(f.io, packages, path)) return packages;
        }
        return null;
    }

    /// Copy `path` into the tree (following symbolic links, as cp -L does)
    /// and, for an ELF object, every library it needs, recursively. A file
    /// that is missing is reported and skipped.
    fn installFile(f: *FreeBsd, path: []const u8) !void {
        if (f.installed.contains(path)) return;
        const from: Dir = f.source(path) orelse {
            std.debug.print("mkrootfs: FreeBSD file {s} not found\n", .{path});
            return;
        };
        try f.installed.put(f.arena, path, {});
        try Dir.copyFile(from, path, f.work, path, f.io, .{ .make_path = true });

        const contents: []const u8 = try from.readFileAlloc(f.io, path, f.arena, .unlimited);
        for (try neededLibraries(f.arena, contents)) |soname| {
            const library: []const u8 = (try f.findLibrary(soname)) orelse {
                std.debug.print("mkrootfs: {s} needs {s}, not found\n", .{ path, soname });
                continue;
            };
            try f.installFile(library);
        }
    }

    /// The path of the library called `soname`, in the run-time linker's
    /// search order.
    fn findLibrary(f: *const FreeBsd, soname: []const u8) !?[]const u8 {
        for (LIBRARY_DIRS) |dir| {
            const path: []const u8 = try std.fmt.allocPrint(f.arena, "{s}/{s}", .{ dir, soname });
            if (f.source(path) != null) return path;
        }
        return null;
    }

    /// Make `link` in the tree point at `target`, replacing what was there.
    fn symlink(f: *const FreeBsd, target: []const u8, link: []const u8) !void {
        f.work.deleteFile(f.io, link) catch {};
        try f.work.symLink(f.io, target, link, .{});
    }

    /// A native Renux tool in /bin would shadow FreeBSD's copy of the same
    /// command in /usr/bin, or a package's in /usr/local/bin, since PATH
    /// searches /bin first: let FreeBSD's win.
    fn preferFreeBsdCommands(f: *const FreeBsd) !void {
        for ([_][]const []const u8{ FREEBSD_PROGRAMS, PACKAGE_PROGRAMS }) |list| {
            for (list) |path| {
                if (!std.mem.startsWith(u8, path, "usr/bin/") and !std.mem.startsWith(u8, path, "usr/local/bin/")) continue;
                if (!exists(f.io, f.work, path)) continue;
                const native: []const u8 = try std.fmt.allocPrint(f.arena, "bin/{s}", .{std.fs.path.basename(path)});
                if (!f.installed.contains(native)) f.work.deleteFile(f.io, native) catch {};
            }
        }
        // GNU nano, when installed, replaces Renux's editor under both names.
        if (exists(f.io, f.work, "usr/local/bin/nano")) f.work.deleteFile(f.io, "bin/edit") catch {};
    }

    /// The configuration FreeBSD's login path and programs read.
    fn installConfiguration(f: *const FreeBsd) !void {
        const io: Io = f.io;
        const work: Dir = f.work;
        for ([_][]const u8{ "etc/pam.d", "root", "usr/share/misc" }) |dir| try work.createDirPath(io, dir);

        for (FREEBSD_ETC) |name| {
            const path: []const u8 = try std.fmt.allocPrint(f.arena, "etc/{s}", .{name});
            if (exists(io, f.base, path)) try Dir.copyFile(f.base, path, work, path, io, .{});
        }
        try f.serialConsolesUseXterm();
        for (FREEBSD_PAM_SERVICES) |name| {
            const path: []const u8 = try std.fmt.allocPrint(f.arena, "etc/pam.d/{s}", .{name});
            try Dir.copyFile(f.base, path, work, path, io, .{});
        }
        for (FREEBSD_ROOT_DOTFILES) |name| {
            const path: []const u8 = try std.fmt.allocPrint(f.arena, "root/{s}", .{name});
            try Dir.copyFile(f.base, path, work, path, io, .{});
        }
        try setMode(io, work, "root", 0o700);
        try setMode(io, work, "etc/master.passwd", 0o600);
        try setMode(io, work, "etc/spwd.db", 0o600);

        // The terminal database (ncurses reads termcap on FreeBSD), with the
        // xterm fix; /etc/termcap links to it, as on FreeBSD.
        try Dir.copyFile(f.base, "usr/share/misc/termcap.db", work, "usr/share/misc/termcap.db", io, .{});
        const termcap: []const u8 = try f.base.readFileAlloc(io, "usr/share/misc/termcap", f.arena, .unlimited);
        try work.writeFile(io, .{ .sub_path = "usr/share/misc/termcap", .data = try std.mem.concat(f.arena, u8, &.{ XTERM_NEW_ENTRY, termcap }) });
        try f.symlink("/usr/share/misc/termcap", "etc/termcap");

        // The C.UTF-8 locale, FreeBSD's default (login.conf's lang=C.UTF-8),
        // so the shell and the utilities handle UTF-8 text.
        if (f.base.openDir(io, "usr/share/locale/C.UTF-8", .{ .iterate = true })) |locale| {
            var source_dir: Dir = locale;
            defer source_dir.close(io);
            var target: Dir = try work.createDirPathOpen(io, "usr/share/locale/C.UTF-8", .{ .open_options = .{ .iterate = true } });
            defer target.close(io);
            try copyTree(io, source_dir, target);
        } else |_| {}

        // The tips fortune(6) shows at login.
        if (f.base.openDir(io, "usr/share/games/fortune", .{ .iterate = true })) |fortune| {
            var source_dir: Dir = fortune;
            defer source_dir.close(io);
            try work.createDirPath(io, "usr/share/games/fortune");
            var it: Dir.Iterator = source_dir.iterate();
            while (try it.next(io)) |entry| {
                if (!std.mem.startsWith(u8, entry.name, "freebsd-tips")) continue;
                const path: []const u8 = try std.fmt.allocPrint(f.arena, "usr/share/games/fortune/{s}", .{entry.name});
                try Dir.copyFile(source_dir, entry.name, work, path, io, .{});
            }
        } else |_| {}

        try f.offerBash();

        // The message of the day login(1) shows (login.conf's welcome=), the
        // login records, and FreeBSD's copyright notice.
        try Dir.copyFile(Dir.cwd(), RENUX_ETC ++ "/motd.template", work, "var/run/motd", io, .{});
        try work.writeFile(io, .{ .sub_path = "var/log/utx.log", .data = "" });
        try Dir.copyFile(f.base, "COPYRIGHT", work, "COPYRIGHT.FreeBSD", io, .{});
    }

    /// FreeBSD's /etc/ttys gives the serial consoles (ttyu*) TERM=vt100,
    /// which has no alternate screen. A terminal attached to a serial port
    /// today is xterm-compatible, so give them xterm.
    fn serialConsolesUseXterm(f: *const FreeBsd) !void {
        if (!exists(f.io, f.work, "etc/ttys")) return;
        const ttys: []const u8 = try f.work.readFileAlloc(f.io, "etc/ttys", f.arena, .unlimited);
        var out: std.ArrayList(u8) = .empty;
        var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, ttys, '\n');
        var first: bool = true;
        while (lines.next()) |line| {
            if (!first) try out.append(f.arena, '\n');
            first = false;
            const vt100: ?usize = if (std.mem.startsWith(u8, line, "ttyu")) std.mem.indexOf(u8, line, "vt100") else null;
            if (vt100) |at| {
                try out.appendSlice(f.arena, line[0..at]);
                try out.appendSlice(f.arena, "xterm");
                try out.appendSlice(f.arena, line[at + "vt100".len ..]);
            } else {
                try out.appendSlice(f.arena, line);
            }
        }
        try f.work.writeFile(f.io, .{ .sub_path = "etc/ttys", .data = out.items });
    }

    /// The system shell is /bin/sh (FreeBSD's sh, BSD-licensed): the base
    /// scripts, the single-user shell and every #!/bin/sh expect it. bash
    /// (GPLv3), when fetched, is offered through chsh(1) by listing it in
    /// /etc/shells, but is not the default login shell.
    fn offerBash(f: *const FreeBsd) !void {
        const bash: []const u8 = "/usr/local/bin/bash";
        if (!exists(f.io, f.work, bash[1..])) return;
        const shells: []const u8 = f.work.readFileAlloc(f.io, "etc/shells", f.arena, .unlimited) catch "";
        var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, shells, '\n');
        const listed: bool = while (lines.next()) |line| {
            if (std.mem.eql(u8, line, bash)) break true;
        } else false;
        if (!listed) {
            const separator: []const u8 = if (shells.len > 0 and shells[shells.len - 1] != '\n') "\n" else "";
            try f.work.writeFile(f.io, .{ .sub_path = "etc/shells", .data = try std.mem.concat(f.arena, u8, &.{ shells, separator, bash, "\n" }) });
        }
        // So a user who does switch to bash still has a profile it reads.
        if (exists(f.io, f.work, "root/.profile") and !exists(f.io, f.work, "root/.bash_profile")) {
            try Dir.copyFile(f.work, "root/.profile", f.work, "root/.bash_profile", f.io, .{});
        }
    }
};

/// The names of the shared libraries an ELF object needs (its DT_NEEDED
/// entries), or none when `contents` is not a 64-bit ELF file or is linked
/// statically.
fn neededLibraries(arena: Allocator, contents: []const u8) ![]const []const u8 {
    if (contents.len < @sizeOf(elf.Elf64.Ehdr) or !std.mem.eql(u8, contents[0..4], elf.MAGIC)) return &.{};
    const header: elf.Elf64.Ehdr = std.mem.bytesToValue(elf.Elf64.Ehdr, contents[0..@sizeOf(elf.Elf64.Ehdr)]);
    if (header.ident.class != .@"64" or header.shentsize != @sizeOf(elf.Elf64.Shdr)) return &.{};

    var names: std.ArrayList([]const u8) = .empty;
    for (0..header.shnum) |index| {
        const dynamic: elf.Elf64.Shdr = sectionHeader(contents, header, index) orelse return &.{};
        if (dynamic.type != .DYNAMIC) continue;
        // The dynamic section names its string table in sh_link.
        const strings: elf.Elf64.Shdr = sectionHeader(contents, header, dynamic.link) orelse return &.{};
        if (strings.offset + strings.size > contents.len) return &.{};
        const string_table: []const u8 = contents[@intCast(strings.offset)..][0..@intCast(strings.size)];

        var offset: u64 = dynamic.offset;
        while (offset + @sizeOf(elf.Elf64_Dyn) <= @min(dynamic.offset + dynamic.size, contents.len)) : (offset += @sizeOf(elf.Elf64_Dyn)) {
            const entry: elf.Elf64_Dyn = std.mem.bytesToValue(elf.Elf64_Dyn, contents[@intCast(offset)..][0..@sizeOf(elf.Elf64_Dyn)]);
            if (entry.d_tag == elf.DT_NULL) break;
            if (entry.d_tag != elf.DT_NEEDED or entry.d_val >= string_table.len) continue;
            try names.append(arena, std.mem.sliceTo(string_table[@intCast(entry.d_val)..], 0));
        }
    }
    return names.items;
}

/// Section header `index` of an ELF file, or null when it lies outside it.
fn sectionHeader(contents: []const u8, header: elf.Elf64.Ehdr, index: usize) ?elf.Elf64.Shdr {
    const offset: u64 = header.shoff + @as(u64, index) * @sizeOf(elf.Elf64.Shdr);
    if (offset + @sizeOf(elf.Elf64.Shdr) > contents.len) return null;
    return std.mem.bytesToValue(elf.Elf64.Shdr, contents[@intCast(offset)..][0..@sizeOf(elf.Elf64.Shdr)]);
}

// -- file helpers --------------------------------------------------------------

/// True when `path` exists under `dir` (following symbolic links).
fn exists(io: Io, dir: Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{}) catch return false;
    return true;
}

/// Set the permission bits of `path` under `dir` (chmod).
fn setMode(io: Io, dir: Dir, path: []const u8, mode: std.posix.mode_t) !void {
    try dir.setFilePermissions(io, path, .fromMode(mode), .{});
}

/// Copy everything in `from` into `to`, as `cp -a from/. to/` does: files
/// keep their permissions, symbolic links are copied as links, and existing
/// files are replaced.
fn copyTree(io: Io, from: Dir, to: Dir) !void {
    var it: Dir.Iterator = from.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var source: Dir = try from.openDir(io, entry.name, .{ .iterate = true });
                defer source.close(io);
                var target: Dir = try to.createDirPathOpen(io, entry.name, .{ .open_options = .{ .iterate = true } });
                defer target.close(io);
                try copyTree(io, source, target);
            },
            .sym_link => {
                var buf: [Dir.max_path_bytes]u8 = undefined;
                const len: usize = try from.readLink(io, entry.name, &buf);
                to.deleteFile(io, entry.name) catch {};
                try to.symLink(io, buf[0..len], entry.name, .{});
            },
            else => try Dir.copyFile(from, entry.name, to, entry.name, io, .{}),
        }
    }
}

/// The space the tree under `dir` takes, in KiB, as du(1) would count it on a
/// file system with 4 KiB blocks: each file rounded up to whole blocks, one
/// block per directory, nothing for a symbolic link.
fn diskUsageKib(io: Io, dir: Dir) !u64 {
    const BLOCK: u64 = 4096;
    var total: u64 = BLOCK;
    var it: Dir.Iterator = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub: Dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                total += (try diskUsageKib(io, sub)) * 1024;
            },
            .sym_link => {},
            else => {
                const st: Io.File.Stat = try dir.statFile(io, entry.name, .{});
                total += std.mem.alignForward(u64, st.size, BLOCK);
            },
        }
    }
    return total / 1024;
}
