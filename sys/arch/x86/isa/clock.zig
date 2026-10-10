// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// System clock (8254 PIT) driver.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/isa/clock.c, reduced to
// the timer half: it programs PIT channel 0 as a periodic tick, registers the
// tick handler on IRQ0 and unmasks the line. The wall-clock half (mc146818 RTC)
// is not implemented yet.

const isa: type = @import("../../../dev/isa/isareg.zig");
const pit: type = @import("../../../dev/ic/i8253reg.zig");
const bus_space: type = @import("../x86/bus_space.zig");
const intr: type = @import("../x86/intr.zig");
const intrdefs: type = @import("../include/intrdefs.zig");
const pic: type = @import("../x86/i8259.zig");
const prf: type = @import("../../../kern/subr_prf.zig");

/// Tick rate in Hz.
pub const HZ: u32 = 100;

var ticks: u64 = 0;

fn outb(port: u16, value: u8) void {
    bus_space.write1(.io, port, 0, value);
}

/// Program the PIT and start delivering ticks.
pub fn init() void {
    const divisor: u16 = @intCast(pit.TIMER_FREQ / HZ);

    outb(isa.IO_TIMER1 + pit.TIMER_MODE, pit.TIMER_SEL0 | pit.TIMER_LSB_MSB | pit.TIMER_MODE_SQW);
    outb(isa.IO_TIMER1 + pit.TIMER_CNTR0, @truncate(divisor));
    outb(isa.IO_TIMER1 + pit.TIMER_CNTR0, @truncate(divisor >> 8));

    intr.register(intrdefs.irqVector(0), tick);
    pic.enableIrq(0);
}

/// Ticks elapsed since init().
pub fn tickCount() u64 {
    return ticks;
}

fn tick() void {
    ticks += 1;
    if (ticks % HZ == 0) {
        prf.print(".");
    }
}
