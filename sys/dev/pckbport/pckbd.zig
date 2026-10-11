// SPDX-License-Identifier: GPL-2.0-only
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

// Scan codes for the shift keys (set 1).
const SC_LSHIFT: u8 = 0x2a;
const SC_RSHIFT: u8 = 0x36;

var shift_down: bool = false;

/// IRQ 1 handler: consume every pending scan code.
fn handler() void {
    while ((pckbc.status() & pckbc.STATUS_OUTPUT_FULL) != 0) {
        const scancode: u8 = pckbc.readData();
        if ((pckbc.status() & pckbc.STATUS_AUX) != 0) {
            continue; // mouse byte; not for us
        }

        const code: u8 = scancode & 0x7f;
        const released: bool = (scancode & 0x80) != 0;

        if (code == SC_LSHIFT or code == SC_RSHIFT) {
            shift_down = !released;
            continue;
        }
        if (released) {
            continue; // ignore other key releases
        }

        const table = if (shift_down) &keymap.shifted else &keymap.normal;
        const ch: u8 = table[code];
        if (ch != 0) {
            cons.cnInput(ch);
        }
    }
}

/// Bring up the keyboard: initialise the controller and hook IRQ 1.
pub fn init() void {
    pckbc.init();
    arch.intr.register(arch.intrdefs.irqVector(1), handler);
    arch.pic.enableIrq(1);
}

fn pckbdInit(_: ?*const anyopaque) callconv(.c) void {
    init();
}

comptime {
    sysinit.SYSINIT("sysinit_pckbd", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_FIRST, pckbdInit, null);
}
