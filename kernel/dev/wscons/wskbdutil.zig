// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Keyboard input helpers shared by the keyboard drivers.
//
// The Zig counterpart of NetBSD's sys/dev/wscons/wskbdutil.c, reduced to what
// the console needs: the escape sequences an xterm sends for the editing,
// cursor and function keys, and the control characters produced with Ctrl.
// The PS/2 driver (pckbd) and the USB driver (ukbd) both translate their keys
// to PC set 1 scan codes and come here.

const cons: type = @import("../cons.zig");

/// Push a byte sequence on the console input queue.
pub fn emit(seq: []const u8) void {
    for (seq) |c| {
        cons.cnInput(c);
    }
}

/// Translate an extended (0xE0-prefixed) set 1 make code into an ANSI
/// sequence. When the terminal is in application cursor mode (DECCKM) the
/// arrows and Home/End use the `\eO` forms the terminfo entries expect.
pub fn extendedKey(code: u8) void {
    const app: bool = cons.cnAppCursor();
    switch (code) {
        0x48 => emit(if (app) "\x1bOA" else "\x1b[A"), // up
        0x50 => emit(if (app) "\x1bOB" else "\x1b[B"), // down
        0x4d => emit(if (app) "\x1bOC" else "\x1b[C"), // right
        0x4b => emit(if (app) "\x1bOD" else "\x1b[D"), // left
        0x47 => emit(if (app) "\x1bOH" else "\x1b[H"), // Home
        0x4f => emit(if (app) "\x1bOF" else "\x1b[F"), // End
        0x53 => emit("\x1b[3~"), // Delete
        0x49 => emit("\x1b[5~"), // Page Up
        0x51 => emit("\x1b[6~"), // Page Down
        0x52 => emit("\x1b[2~"), // Insert
        else => {},
    }
}

/// The sequence an xterm sends for function key F`n` (1 to 12).
pub fn functionKey(n: u8) void {
    const seqs = [_][]const u8{
        "\x1bOP",   "\x1bOQ",   "\x1bOR",   "\x1bOS",
        "\x1b[15~", "\x1b[17~", "\x1b[18~", "\x1b[19~",
        "\x1b[20~", "\x1b[21~", "\x1b[23~", "\x1b[24~",
    };
    if (n >= 1 and n <= seqs.len) emit(seqs[n - 1]);
}

/// Map a printable character to the control character produced with Ctrl held
/// (Ctrl+A..Ctrl+Z and the punctuation keys, as the BSD consoles do).
pub fn controlChar(ch: u8) u8 {
    if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
        return ch & 0x1f;
    }
    return switch (ch) {
        '[', '3' => 0x1b,
        '\\', '4' => 0x1c,
        ']', '5' => 0x1d,
        '6' => 0x1e,
        '-', '7', '/' => 0x1f,
        '2', ' ', '@', '`' => 0x00,
        '8' => 0x7f, // Ctrl+8 is DEL
        else => ch,
    };
}
