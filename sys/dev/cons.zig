// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// MI console switch.
//
// Mirrors the role of sys/dev/cons.c in NetBSD: it is the single place through
// which the kernel writes to (and later reads from) the system console. Drivers
// register a Console here; nothing above this layer knows which device is
// installed. The MD port picks the initial console via consinit().

/// A console device, described by callbacks. Only putc is required; getc is
/// optional and used by the (future) kernel debugger and getchar path.
pub const Console: type = struct {
    /// Emit one character.
    putc: *const fn (c: u8) void,
    /// Receive one character, if the device can.
    getc: ?*const fn () u8 = null,
};

/// The currently selected console, or null before consinit() runs.
var console: ?Console = null;

/// Install `tab` as the system console. Called from MD consinit().
pub fn cn_set_tab(tab: Console) void {
    console = tab;
}

/// True when a console has been installed.
pub fn cn_attached() bool {
    return console != null;
}

/// Emit one character on the console. A no-op before a console is attached,
/// which is what lets very early code run safely.
pub fn cnputc(c: u8) void {
    if (console) |tab| {
        tab.putc(c);
    }
}

/// Receive one character from the console, or 0 if none is available.
pub fn cngetc() u8 {
    if (console) |tab| {
        if (tab.getc) |getc| {
            return getc();
        }
    }
    return 0;
}

/// Emit a byte string on the console.
pub fn cnwrite(s: []const u8) void {
    for (s) |c| {
        cnputc(c);
    }
}
