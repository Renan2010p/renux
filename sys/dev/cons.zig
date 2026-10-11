// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// MI console switch.
//
// Mirrors the role of sys/dev/cons.c in NetBSD: it is the single place through
// which the kernel writes to (and later reads from) the system console. Any
// number of drivers register here; output is broadcast to all of them, so the
// kernel can print to serial and to a screen at the same time. Nothing above
// this layer knows which devices are installed.

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
