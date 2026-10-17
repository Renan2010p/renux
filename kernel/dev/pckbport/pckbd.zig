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
const wskbdutil: type = @import("../wscons/wskbdutil.zig");
const arch: type = @import("../../arch/arch.zig");
const sysinit: type = @import("../../sys/sysinit.zig");
const subr_bus: type = @import("../../core/subr_bus.zig");

const kbdc_dev: subr_bus.Device = .{
    .name = "atkbdc",
    .desc = "Keyboard controller (i8042)",
    .parent = "isa0",
};

const kbd_dev: subr_bus.Device = .{
    .name = "atkbd",
    .desc = "AT Keyboard",
    .parent = "atkbdc0",
};

// Scan codes for the modifier keys (set 1).
const SC_LSHIFT: u8 = 0x2a;
const SC_RSHIFT: u8 = 0x36;
const SC_LCTRL: u8 = 0x1d;

var shift_down: bool = false;
var ctrl_down: bool = false;
var extended: bool = false;

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
                wskbdutil.extendedKey(code);
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
            ch = wskbdutil.controlChar(ch);
        }
        if (ch != 0 or ctrl_down) {
            cons.cnInput(ch);
        }
    }
}

/// Bring up the keyboard: initialise the controller and hook IRQ 1. Returns
/// false when the machine has no i8042 (a USB keyboard is then the console's).
pub fn init() bool {
    if (!pckbc.init()) return false;
    arch.intr.register(arch.intrdefs.irqVector(1), handler);
    arch.pic.enableIrq(1);
    return true;
}

fn pckbdInit(_: ?*const anyopaque) callconv(.c) void {
    if (!init()) return;
    subr_bus.announce(&kbdc_dev, " port 0x60,0x64", .{});
    subr_bus.announce(&kbd_dev, " irq 1", .{});
}

comptime {
    sysinit.SYSINIT("sysinit_pckbd", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_THIRD, pckbdInit, null);
}
