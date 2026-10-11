// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Machine-independent system call numbers and wrappers.
//
// The Zig counterpart of NetBSD/FreeBSD lib/libc/sys: the portable wrappers a
// program calls (write, read, exit, ...). They forward to the architecture's
// primitive through lib/libc/arch, so nothing here names a register or an
// instruction.
//
// The numbers are shared with the kernel (sys/sys/syscall.zig); NetBSD and
// FreeBSD keep them in sys/sys/syscall.h, installed for both kernel and libc.

const arch: type = @import("../arch/arch.zig");

pub const SYS_exit: u64 = 1;
pub const SYS_fork: u64 = 2;
pub const SYS_read: u64 = 3;
pub const SYS_write: u64 = 4;
pub const SYS_open: u64 = 5;
pub const SYS_close: u64 = 6;
pub const SYS_wait4: u64 = 7;
pub const SYS_unlink: u64 = 10;
pub const SYS_chdir: u64 = 12;
pub const SYS_brk: u64 = 17;
pub const SYS_lseek: u64 = 19;
pub const SYS_getpid: u64 = 20;
pub const SYS_setuid: u64 = 23;
pub const SYS_getuid: u64 = 24;
pub const SYS_kill: u64 = 37;
pub const SYS_dup: u64 = 41;
pub const SYS_ioctl: u64 = 54;
pub const SYS_execve: u64 = 59;
pub const SYS_dup2: u64 = 90;
pub const SYS_munmap: u64 = 73;
pub const SYS_gettimeofday: u64 = 116;
pub const SYS_mkdir: u64 = 136;
pub const SYS_rmdir: u64 = 137;
pub const SYS_stat: u64 = 188;
pub const SYS_fstat: u64 = 189;
pub const SYS_getdents: u64 = 272;
pub const SYS_getcwd: u64 = 326;
pub const SYS_sigprocmask: u64 = 340;
pub const SYS_klog: u64 = 500;
pub const SYS_sigaction: u64 = 416;
pub const SYS_sigreturn: u64 = 417;
pub const SYS_mmap: u64 = 477;

/// Signals (NetBSD numbers).
pub const SIGHUP: u64 = 1;
pub const SIGINT: u64 = 2;
pub const SIGQUIT: u64 = 3;
pub const SIGKILL: u64 = 9;
pub const SIGPIPE: u64 = 13;
pub const SIGALRM: u64 = 14;
pub const SIGTERM: u64 = 15;
pub const SIGCHLD: u64 = 20;
pub const SIGWINCH: u64 = 28;
pub const SIGUSR1: u64 = 30;
pub const SIGUSR2: u64 = 31;

/// Special handler values.
pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;

/// An installed signal action.
pub const Sigaction: type = extern struct {
    handler: u64,
    mask: u64,
};

/// open(2) flags (the subset in use).
pub const O_RDONLY: u64 = 0;
pub const O_WRONLY: u64 = 1;
pub const O_RDWR: u64 = 2;
pub const O_CREAT: u64 = 0x0200;
pub const O_TRUNC: u64 = 0x0400;
pub const O_DIRECTORY: u64 = 0x20000;

/// Directory entry, matching the kernel's struct dirent (16 bytes of fields
/// padded to 24 by the C ABI).
pub const Dirent: type = extern struct {
    ino: u64,
    off: i64,
    reclen: u16,
    type: u8,
    namlen: u16,
};

/// Directory entry types (DT_*).
pub const DT_DIR: u8 = 4;
pub const DT_REG: u8 = 8;

/// Terminal attributes, matching the kernel's struct termios.
pub const Termios: type = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_cc: [20]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

/// Window size, matching the kernel's struct winsize.
pub const Winsize: type = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const IOC_OUT: u64 = 0x40000000;
const IOC_IN: u64 = 0x80000000;

fn ioc(dir: u64, group: u8, num: u8, len: usize) u64 {
    return dir | (@as(u64, len) << 16) | (@as(u64, group) << 8) | @as(u64, num);
}

/// Get terminal attributes (a struct termios).
pub const TIOCGETA: u64 = ioc(IOC_OUT, 't', 19, @sizeOf(Termios));
/// Set terminal attributes (a struct termios).
pub const TIOCSETA: u64 = ioc(IOC_IN, 't', 20, @sizeOf(Termios));
/// Get the window size (a struct winsize).
pub const TIOCGWINSZ: u64 = ioc(IOC_OUT, 't', 104, @sizeOf(Winsize));
/// Set the window size (a struct winsize).
pub const TIOCSWINSZ: u64 = ioc(IOC_IN, 't', 103, @sizeOf(Winsize));

// Local mode flags (c_lflag), the subset in use.
pub const ECHO: u32 = 0x00000008;
pub const ICANON: u32 = 0x00000100;

/// File status, matching the kernel's struct stat (sys/sys/stat.h).
pub const Stat: type = extern struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: u64,
    blksize: u64,
    blocks: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
};

/// Issue a system call with up to six arguments.
pub fn syscall(number: u64, args: [6]u64) u64 {
    return arch.syscall.syscall(number, args[0], args[1], args[2], args[3], args[4], args[5]);
}

/// Write `buf` to file descriptor `fd`; returns the number of bytes written.
pub fn write(fd: u64, buf: []const u8) u64 {
    return syscall(SYS_write, .{ fd, @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

/// Read up to `buf.len` bytes from file descriptor `fd`.
pub fn read(fd: u64, buf: []u8) u64 {
    return syscall(SYS_read, .{ fd, @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

/// Open `path`; returns a descriptor or a negative value.
pub fn open(path: [*:0]const u8, flags: u64, mode: u64) i64 {
    const r: u64 = syscall(SYS_open, .{ @intFromPtr(path), flags, mode, 0, 0, 0 });
    return @bitCast(r);
}

/// Close file descriptor `fd`.
pub fn close(fd: u64) i64 {
    const r: u64 = syscall(SYS_close, .{ fd, 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Reposition the offset of file descriptor `fd`.
pub fn lseek(fd: u64, off: i64, whence: u64) i64 {
    const r: u64 = syscall(SYS_lseek, .{ fd, @bitCast(off), whence, 0, 0, 0 });
    return @bitCast(r);
}

/// Duplicate `oldfd` onto `newfd`.
pub fn dup2(oldfd: u64, newfd: u64) i64 {
    const r: u64 = syscall(SYS_dup2, .{ oldfd, newfd, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Fill in `st` for file descriptor `fd`.
pub fn fstat(fd: u64, st: *Stat) i64 {
    const r: u64 = syscall(SYS_fstat, .{ fd, @intFromPtr(st), 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Fill in `st` for `path`.
pub fn stat(path: [*:0]const u8, st: *Stat) i64 {
    const r: u64 = syscall(SYS_stat, .{ @intFromPtr(path), @intFromPtr(st), 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Read directory entries into `buf`; returns the number of bytes read.
pub fn getdents(fd: u64, buf: []u8) u64 {
    return syscall(SYS_getdents, .{ fd, @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

/// Change the working directory to `path`.
pub fn chdir(path: [*:0]const u8) i64 {
    const r: u64 = syscall(SYS_chdir, .{ @intFromPtr(path), 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Create directory `path` with permission bits `mode`.
pub fn mkdir(path: [*:0]const u8, mode: u64) i64 {
    const r: u64 = syscall(SYS_mkdir, .{ @intFromPtr(path), mode, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Remove the empty directory `path`.
pub fn rmdir(path: [*:0]const u8) i64 {
    const r: u64 = syscall(SYS_rmdir, .{ @intFromPtr(path), 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Remove the non-directory `path`.
pub fn unlink(path: [*:0]const u8) i64 {
    const r: u64 = syscall(SYS_unlink, .{ @intFromPtr(path), 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Copy the NUL-terminated working directory path into `buf`.
pub fn getcwd(buf: []u8) i64 {
    const r: u64 = syscall(SYS_getcwd, .{ @intFromPtr(buf.ptr), buf.len, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Perform the control request `cmd` on descriptor `fd`.
pub fn ioctl(fd: u64, cmd: u64, arg: u64) i64 {
    const r: u64 = syscall(SYS_ioctl, .{ fd, cmd, arg, 0, 0, 0 });
    return @bitCast(r);
}

/// Set the program break; returns the new break or a negative errno.
pub fn brkRaw(addr: u64) i64 {
    const r: u64 = syscall(SYS_brk, .{ addr, 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// The real user id.
pub fn getuidRaw() u32 {
    return @truncate(syscall(SYS_getuid, .{ 0, 0, 0, 0, 0, 0 }));
}

/// Set the user id.
pub fn setuid(uid: u32) i64 {
    const r: u64 = syscall(SYS_setuid, .{ uid, 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Copy the kernel message buffer into `buf`; returns the length.
pub fn klogRaw(buf: []u8) i64 {
    const r: u64 = syscall(SYS_klog, .{ @intFromPtr(buf.ptr), buf.len, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// A time value (struct timeval).
pub const Timeval: type = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// Map memory; only anonymous mappings are implemented by the kernel.
pub fn mmapRaw(addr: u64, len: u64, prot: u64, flags: u64, fd: u64, off: u64) i64 {
    const r: u64 = syscall(SYS_mmap, .{ addr, len, prot, flags, fd, off });
    return @bitCast(r);
}

/// Unmap memory.
pub fn munmap(addr: u64, len: u64) i64 {
    const r: u64 = syscall(SYS_munmap, .{ addr, len, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Fill in the current time.
pub fn gettimeofdayRaw(tv: *Timeval) i64 {
    const r: u64 = syscall(SYS_gettimeofday, .{ @intFromPtr(tv), 0, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Set the action for signal `sig`, returning the previous handler.
pub fn signal(sig: u64, handler: u64) u64 {
    var act: Sigaction = .{ .handler = handler, .mask = 0 };
    var old: Sigaction = .{ .handler = 0, .mask = 0 };
    const r: u64 = syscall(SYS_sigaction, .{ sig, @intFromPtr(&act), @intFromPtr(&old), 0, 0, 0 });
    if (r != 0) {
        return SIG_DFL;
    }
    return old.handler;
}

/// Query and/or set the action for signal `sig`.
pub fn sigaction(sig: u64, act: ?*const Sigaction, oact: ?*Sigaction) i64 {
    const r: u64 = syscall(SYS_sigaction, .{
        sig,
        if (act) |a| @intFromPtr(a) else 0,
        if (oact) |o| @intFromPtr(o) else 0,
        0,
        0,
        0,
    });
    return @bitCast(r);
}

/// Send signal `sig` to process `pid`.
pub fn kill(pid: i64, sig: u64) i64 {
    const r: u64 = syscall(SYS_kill, .{ @bitCast(pid), sig, 0, 0, 0, 0 });
    return @bitCast(r);
}

/// Terminate the calling process.
pub fn exit(code: u64) noreturn {
    _ = syscall(SYS_exit, .{ code, 0, 0, 0, 0, 0 });
    unreachable;
}

/// Create a child process: returns 0 in the child, the child's pid in the
/// parent, or a negative value on error.
pub fn fork() i32 {
    const r: u64 = syscall(SYS_fork, .{ 0, 0, 0, 0, 0, 0 });
    return @bitCast(@as(u32, @truncate(r)));
}

/// Replace the process image with `path`, started with `argv`/`envp`. Returns
/// only on failure.
pub fn execve(path: [*:0]const u8, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) i64 {
    const r: u64 = syscall(SYS_execve, .{ @intFromPtr(path), @intFromPtr(argv), @intFromPtr(envp), 0, 0, 0 });
    return @bitCast(r);
}

/// Wait for a child to exit; returns its pid or a negative value.
pub fn wait(status: ?*i32) i32 {
    _ = status;
    const r: u64 = syscall(SYS_wait4, .{ 0, 0, 0, 0, 0, 0 });
    return @bitCast(@as(u32, @truncate(r)));
}

/// The calling process's pid.
pub fn getpid() i32 {
    const r: u64 = syscall(SYS_getpid, .{ 0, 0, 0, 0, 0, 0 });
    return @bitCast(@as(u32, @truncate(r)));
}
