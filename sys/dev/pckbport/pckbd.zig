// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// PS/2 keyboard.
//
// The Zig counterpart of NetBSD's sys/dev/pckbport/pckbd.c, reduced to a US
// keyboard: IRQ 1 drains scan codes from the controller, translates them with
// the MF-II map and feeds the console input queue.

const pckbc: type = @import("../ic/pckbc.zig");
const keymap: type = @import("wskbdmap_mfii.zig");
const cons: type = @import("../cons.zig");
const arch: type = @import("../../arch/arch.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const prf: type = @import("../../kern/subr_prf.zig");

// Scan codes for the modifier keys (set 1).
const SC_LSHIFT: u8 = 0x2a;
const SC_RSHIFT: u8 = 0x36;
const SC_LCTRL: u8 = 0x1d;

var shift_down: bool = false;
var ctrl_down: bool = false;
var extended: bool = false;

/// Push an escape sequence on the console input queue.
fn emit(seq: []const u8) void {
    for (seq) |c| {
        cons.cnInput(c);
    }
}

/// Translate an extended (0xE0-prefixed) make code into an ANSI sequence. When
/// the terminal is in application cursor mode (DECCKM) the arrows and Home/End
/// use the `\eO` forms the terminfo entries expect.
fn extendedKey(code: u8) void {
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

/// Map a printable character to the control character produced with Ctrl held
/// (Ctrl+A..Ctrl+Z and the punctuation keys, as the BSD consoles do).
fn controlChar(ch: u8) u8 {
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

/// IRQ 1 handler: consume every pending scan code. The status register is read
/// once per byte: it describes the byte about to be read, so the mouse/AUX bit
/// must be tested before consuming it (otherwise a mouse byte is mistaken for a
/// scan code).
fn handler() void {
    while (true) {
        const st: u8 = pckbc.status();
        if ((st & pckbc.STATUS_OUTPUT_FULL) == 0) {
            break;
        }
        const scancode: u8 = pckbc.readData();
        if ((st & pckbc.STATUS_AUX) != 0) {
            continue; // mouse byte; not for us
        }

        // 0xE0 introduces an extended key (arrows, Home/End, right Ctrl/Alt).
        if (scancode == 0xe0) {
            extended = true;
            continue;
        }

        const code: u8 = scancode & 0x7f;
        const released: bool = (scancode & 0x80) != 0;

        if (extended) {
            extended = false;
            if (code == SC_LCTRL) {
                ctrl_down = !released; // right Ctrl
                continue;
            }
            if (!released) {
                extendedKey(code);
            }
            continue;
        }

        if (code == SC_LSHIFT or code == SC_RSHIFT) {
            shift_down = !released;
            continue;
        }
        if (code == SC_LCTRL) {
            ctrl_down = !released;
            continue;
        }
        if (released) {
            continue; // ignore other key releases
        }

        const table = if (shift_down) &keymap.shifted else &keymap.normal;
        var ch: u8 = table[code];
        if (ctrl_down) {
            ch = controlChar(ch);
        }
        if (ch != 0 or ctrl_down) {
            cons.cnInput(ch);
        }
    }
}

/// Bring up the keyboard: initialise the controller and hook IRQ 1.
pub fn init() void {
    pckbc.init();
    arch.intr.register(arch.intrdefs.irqVector(1), handler);
    arch.pic.enableIrq(1);
    prf.printLine("pckbc0 at isa0 port 0x60-0x64");
    prf.printLine("pckbd0 at pckbc0");
}

fn pckbdInit(_: ?*const anyopaque) callconv(.c) void {
    init();
}

comptime {
    sysinit.SYSINIT("sysinit_pckbd", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_FIRST, pckbdInit, null);
}
