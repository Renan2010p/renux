// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /sbin/init: the first user process.
//
// Following the BSD startup sequence: in a single-user boot (the kernel passes
// -s) init first offers a shell on the console; then it brings the system up
// to multi-user operation and keeps a getty running on the console.
//
// The multi-user startup is done here, in Zig, rather than by an /etc/rc
// script. It does what Renux supports, in FreeBSD's order and with the
// messages FreeBSD's rc prints, using FreeBSD's own tools when the root
// image carries them:
//
//   1. the shared library search path      ldconfig -elf    (rc.d/ldconfig)
//   2. the password databases, if missing  pwd_mkdb -p      (chpass(1))
//   3. the local file systems in /etc/fstab  mount -a       (rc.d/mountcritlocal)
//   4. the system log daemon               syslogd          (rc.d/syslogd)
//
// A step whose program is not in the image is skipped.
//
// It also answers the signals FreeBSD's init does, which shutdown(8) sends:
// SIGINT reboots, SIGUSR1 halts and SIGUSR2 powers off, after asking every
// process to terminate; SIGTSTP stops it from starting new sessions (what
// reboot(8) sends before it does the shutting down itself).

const libc: type = @import("libc");

/// _IO('t', 97): make the terminal the session's controlling terminal.
const TIOCSCTTY: u64 = 0x20007461;

/// A shutdown asked for by a signal: the reboot(2) flags, or null.
var shutdown_howto: ?u64 = null;
/// SIGTSTP: start no new sessions.
var no_respawn: bool = false;

fn onSignal(sig: c_int) callconv(.c) void {
    switch (@as(u64, @intCast(sig))) {
        libc.syscall.SIGINT => @as(*volatile ?u64, &shutdown_howto).* = libc.syscall.RB_AUTOBOOT,
        libc.syscall.SIGUSR1 => @as(*volatile ?u64, &shutdown_howto).* = libc.syscall.RB_HALT,
        libc.syscall.SIGUSR2 => @as(*volatile ?u64, &shutdown_howto).* = libc.syscall.RB_POWEROFF,
        libc.syscall.SIGTSTP => @as(*volatile bool, &no_respawn).* = true,
        else => {},
    }
}

/// Bring the system down (FreeBSD's death()): ask every process to
/// terminate, give them a moment, kill what is left, then reboot(2).
fn shutdown(howto: u64) noreturn {
    libc.syslog.msg("init", "shutting down");
    _ = libc.syscall.kill(-1, libc.syscall.SIGTERM);
    const pause: libc.syscall.Timespec2 = .{ .tv_sec = 0, .tv_nsec = 200_000_000 };
    var tries: u32 = 0;
    while (tries < 15) : (tries += 1) {
        // Reap what has exited; stop waiting once nothing is left.
        while (true) {
            const r: i32 = libc.syscall.waitNohang();
            if (r <= 0) break;
        }
        if (libc.syscall.kill(-1, 0) < 0) break;
        _ = libc.syscall.nanosleep(&pause, null);
    }
    _ = libc.syscall.kill(-1, libc.syscall.SIGKILL);
    _ = libc.syscall.reboot(howto);
    libc.stdio.puts("init: reboot(2) failed");
    while (true) _ = libc.syscall.nanosleep(&pause, null);
}

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// st_mode bits: any of the execute permissions.
const S_IXANY: u16 = 0o111;

/// True when `path` exists and is executable by someone.
fn isExecutable(path: [*:0]const u8) bool {
    var st: libc.syscall.Stat = undefined;
    return libc.syscall.stat(path, &st) == 0 and (st.mode & S_IXANY) != 0;
}

/// True when `path` exists.
fn exists(path: [*:0]const u8) bool {
    var st: libc.syscall.Stat = undefined;
    return libc.syscall.stat(path, &st) == 0;
}

/// Start `argv[0]` with arguments `argv` in a child. Returns the child's
/// process id, or a negative value when fork(2) failed.
fn spawn(argv: []const ?[*:0]const u8, envp: [*]?[*:0]const u8) i32 {
    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        _ = libc.syscall.execve(argv[0].?, @constCast(argv.ptr), envp);
        libc.syscall.exit(127);
    }
    return pid;
}

/// Run `argv` in a child and wait for it to finish.
fn run(argv: []const ?[*:0]const u8, envp: [*]?[*:0]const u8) void {
    if (spawn(argv, envp) > 0) _ = libc.syscall.wait(null);
}

/// Bring the system up to multi-user operation (what FreeBSD's /etc/rc
/// does; see the steps at the top of this file).
fn multiUserStartup(envp: [*]?[*:0]const u8) void {
    libc.syslog.msg("init", "multi-user startup");

    // FreeBSD packages install their libraries in /usr/local/lib.
    if (isExecutable("/sbin/ldconfig")) {
        libc.stdio.puts("ELF ldconfig path: /lib /usr/lib /usr/local/lib");
        run(&.{ "/sbin/ldconfig", "-elf", "/lib", "/usr/lib", "/usr/local/lib", null }, envp);
    }

    // The root image carries the account files; their databases are built
    // here when the image did not include them.
    if (!exists("/etc/spwd.db") and isExecutable("/usr/sbin/pwd_mkdb")) {
        libc.stdio.puts("Building the password databases.");
        run(&.{ "/usr/sbin/pwd_mkdb", "-p", "/etc/master.passwd", null }, envp);
    }

    if (exists("/etc/fstab") and isExecutable("/sbin/mount")) {
        libc.stdio.printf("Mounting local filesystems:", .{});
        run(&.{ "/sbin/mount", "-a", null }, envp);
        libc.stdio.puts(".");
    }

    // syslogd runs for as long as the system does; init does not wait for it.
    if (isExecutable("/usr/sbin/syslogd")) {
        libc.stdio.puts("Starting syslogd.");
        _ = spawn(&.{ "/usr/sbin/syslogd", null }, envp);
    }

    libc.syslog.msg("init", "multi-user startup complete");
}

/// Run `path` (a shell) in a child and wait for it.
fn runShell(path: [*:0]const u8, envp: [*]?[*:0]const u8) void {
    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        var av: [2]?[*:0]const u8 = .{ path, null };
        _ = libc.syscall.execve(path, @ptrCast(&av), envp);
        libc.stdio.puts("init: cannot exec the shell");
        libc.syscall.exit(1);
    }
    _ = libc.syscall.wait(null);
}

/// Single-user mode, as FreeBSD's init does it: offer a shell on the console
/// and, when it exits, continue to multi-user operation.
fn singleUser(envp: [*]?[*:0]const u8) void {
    libc.syslog.msg("init", "single user mode");
    libc.stdio.printf("Enter full pathname of shell or RETURN for /bin/sh: ", .{});
    var buf: [128:0]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        if (libc.syscall.read(0, &c) != 1 or c[0] == '\n' or c[0] == '\r') break;
        buf[n] = c[0];
        n += 1;
    }
    buf[n] = 0;
    const shell: [*:0]const u8 = if (n == 0) "/bin/sh" else &buf;
    runShell(shell, envp);
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    // The kernel passes -s for a single-user boot.
    var single: bool = false;
    var a: usize = 1;
    while (a < @as(usize, @intCast(argc))) : (a += 1) {
        const arg = argv[a] orelse continue;
        if (arg[0] == '-' and arg[1] == 's') single = true;
    }

    // Attach the console as stdin, stdout and stderr: like the BSD init, open
    // /dev/console and dup2() it onto 0, 1 and 2.
    const cfd: i64 = libc.syscall.open("/dev/tty", 2, 0);
    if (cfd >= 0) {
        _ = libc.syscall.dup2(@intCast(cfd), 0);
        _ = libc.syscall.dup2(@intCast(cfd), 1);
        _ = libc.syscall.dup2(@intCast(cfd), 2);
        if (cfd > 2) {
            _ = libc.syscall.close(@intCast(cfd));
        }
    }

    const handler: u64 = @intFromPtr(&onSignal);
    _ = libc.syscall.signal(libc.syscall.SIGINT, handler);
    _ = libc.syscall.signal(libc.syscall.SIGUSR1, handler);
    _ = libc.syscall.signal(libc.syscall.SIGUSR2, handler);
    _ = libc.syscall.signal(libc.syscall.SIGTSTP, handler);
    // SIGTERM would take FreeBSD's init to single user; Renux's stays put.
    _ = libc.syscall.signal(libc.syscall.SIGTERM, libc.syscall.SIG_IGN);
    _ = libc.syscall.signal(libc.syscall.SIGHUP, libc.syscall.SIG_IGN);

    if (single) {
        singleUser(envp);
    }

    multiUserStartup(envp);

    // Respawn getty on the console, like a real init(8): when the shell it
    // started exits, a new getty (and so a new login) is started.
    while (true) {
        if (shutdown_howto) |howto| shutdown(howto);
        if (@as(*volatile bool, &no_respawn).*) {
            // Sessions are off: just reap children until told what to do.
            const pause: libc.syscall.Timespec2 = .{ .tv_sec = 1, .tv_nsec = 0 };
            _ = libc.syscall.waitNohang();
            _ = libc.syscall.nanosleep(&pause, null);
            continue;
        }
        const gpid: i32 = libc.syscall.fork();
        if (gpid == 0) {
            // A login session of its own, as FreeBSD's init gives each
            // getty; the terminal becomes its controlling terminal.
            _ = libc.syscall.setsid();
            _ = libc.syscall.ioctl(0, TIOCSCTTY, 0);
            // As /etc/ttys runs it on FreeBSD: the "Pc" gettytab entry (8-bit,
            // no parity) on the terminal already open as stdin ("-").
            var av: [4]?[*:0]const u8 = .{ "getty", "Pc", "-", null };
            _ = libc.syscall.execve("/usr/libexec/getty", @ptrCast(&av), envp);
            libc.syscall.exit(1);
        }
        // Wait for this session's getty (and the login and shell it became)
        // to exit. Other children end here too: every orphaned process is
        // re-parented to init, and init only reaps them. A signal ends the
        // wait early (EINTR); keep waiting unless a shutdown was asked for.
        while (true) {
            const r: i32 = libc.syscall.wait(null);
            if (r == gpid or @as(*volatile ?u64, &shutdown_howto).* != null) break;
            if (r < 0 and r != -4) break; // not EINTR: no children left
        }
        if (@as(*volatile ?u64, &shutdown_howto).*) |howto| shutdown(howto);
        libc.syslog.msg("init", "getty exited, respawning");
    }
}
