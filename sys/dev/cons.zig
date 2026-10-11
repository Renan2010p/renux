// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// MI console switch and the console device.
//
// This mirrors NetBSD's sys/dev/cons.c: the single place through which the
// kernel writes to (and reads from) the system console, plus the /dev/console
// character device (cons_cdevsw) built on those same routines. Any number of
// drivers register here; output is broadcast to all of them, so the kernel can
// print to serial and to a screen at the same time. Nothing above this layer
// knows which devices are installed.

const conf: type = @import("../sys/conf.zig");
const errno: type = @import("../sys/errno.zig");
const sysinit: type = @import("../sys/sysinit.zig");

/// Maximum number of attached consoles.
pub const MAX_CONSOLES: usize = 4;

/// A console device, described by callbacks. Only putc is required; getc is
/// optional and used by the (future) kernel debugger and getchar path.
pub const Console: type = struct {
    /// Emit one character.
    putc: *const fn (c: u8) void,
    /// Receive one character, blocking, if the device can.
    getc: ?*const fn () u8 = null,
    /// Receive one character without blocking, if one is available.
    trygetc: ?*const fn () ?u8 = null,
    /// Set the foreground colour (RGB), if the device can.
    setfg: ?*const fn (r: u8, g: u8, b: u8) void = null,
};

var consoles: [MAX_CONSOLES]Console = undefined;
var nconsoles: usize = 0;

// Input queue fed by input drivers (e.g. the PS/2 keyboard) and drained by
// cngetcPoll().
const INPUT_SIZE: usize = 128;
var input_buf: [INPUT_SIZE]u8 = undefined;
var input_head: usize = 0;
var input_tail: usize = 0;

/// Push one character onto the console input queue.
pub fn cnInput(c: u8) void {
    const next: usize = (input_tail + 1) % INPUT_SIZE;
    if (next == input_head) {
        return; // queue full; drop
    }
    input_buf[input_tail] = c;
    input_tail = next;
}

fn inputPop() ?u8 {
    if (input_head == input_tail) {
        return null;
    }
    const c: u8 = input_buf[input_head];
    input_head = (input_head + 1) % INPUT_SIZE;
    return c;
}

/// Register `tab` as a system console. Called from MD consinit().
pub fn cn_attach(tab: Console) void {
    if (nconsoles >= MAX_CONSOLES) {
        return;
    }
    consoles[nconsoles] = tab;
    nconsoles += 1;
}

/// True when at least one console has been attached.
pub fn cn_attached() bool {
    return nconsoles != 0;
}

/// Emit one character on every attached console. A no-op before any console is
/// attached, which is what lets very early code run safely.
pub fn cnputc(c: u8) void {
    var i: usize = 0;
    while (i < nconsoles) : (i += 1) {
        consoles[i].putc(c);
    }
}

/// Receive one character from the first console able to provide one, else 0.
pub fn cngetc() u8 {
    var i: usize = 0;
    while (i < nconsoles) : (i += 1) {
        if (consoles[i].getc) |getc| {
            return getc();
        }
    }
    return 0;
}

/// Receive one character from the first console that has one ready, else null.
/// Characters pushed by input drivers (cnInput) take priority.
pub fn cngetcPoll() ?u8 {
    if (inputPop()) |c| {
        return c;
    }
    var i: usize = 0;
    while (i < nconsoles) : (i += 1) {
        if (consoles[i].trygetc) |trygetc| {
            if (trygetc()) |c| {
                return c;
            }
        }
    }
    return null;
}

/// Set the console foreground colour (RGB) on every console that supports it.
pub fn cnSetColor(r: u8, g: u8, b: u8) void {
    var i: usize = 0;
    while (i < nconsoles) : (i += 1) {
        if (consoles[i].setfg) |setfg| {
            setfg(r, g, b);
        }
    }
}

/// Emit a byte string on the console.
pub fn cnwrite(s: []const u8) void {
    for (s) |c| {
        cnputc(c);
    }
}

/// Major number of the console device.
pub const CONSOLE_MAJOR: usize = 0;

/// Open the console device.
fn cnopen(dev: u64, flags: i32) ?*anyopaque {
    _ = dev;
    _ = flags;
    return null;
}

/// Close the console device.
fn cnclose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

/// Read one byte from the console; -EAGAIN when nothing is ready (the read
/// system call turns that into a blocking wait).
fn cnread(ctx: ?*anyopaque, buf: []u8) isize {
    _ = ctx;
    if (buf.len == 0) {
        return 0;
    }
    const c: u8 = cngetcPoll() orelse return -errno.EAGAIN;
    buf[0] = c;
    return 1;
}

/// Write a byte string to the console.
fn cnwriteDev(ctx: ?*anyopaque, buf: []const u8) isize {
    _ = ctx;
    cnwrite(buf);
    return @intCast(buf.len);
}

/// The console has no control requests (use /dev/tty).
fn cnioctl(ctx: ?*anyopaque, cmd: u64, arg: u64) i32 {
    _ = ctx;
    _ = cmd;
    _ = arg;
    return -errno.ENOTTY;
}

/// The /dev/console character device switch.
const cons_cdevsw: conf.Cdevsw = .{
    .name = "console",
    .open = cnopen,
    .read = cnread,
    .write = cnwriteDev,
    .ioctl = cnioctl,
    .close = cnclose,
};

fn consAttachDev(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(CONSOLE_MAJOR, &cons_cdevsw);
}

comptime {
    sysinit.SYSINIT("sysinit_consdev", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_FIRST, consAttachDev, null);
}
