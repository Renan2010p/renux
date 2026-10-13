// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// AT real-time clock (MC146818-compatible CMOS clock).
//
// The Zig counterpart of FreeBSD's sys/x86/isa/atrtc.c, reduced to reading the
// time of day once at boot (FreeBSD's inittodr()): the kernel's notion of the
// boot time comes from here, so date(1), ls -l and the login banner show the
// real wall-clock time. The periodic tick stays with the i8254 (clock.zig).

const isa: type = @import("../../../dev/isa/isareg.zig");
const bus_space: type = @import("../x86/bus_space.zig");
const subr_bus: type = @import("../../../kern/subr_bus.zig");
const subr_clock: type = @import("../../../kern/subr_clock.zig");
const kern_time: type = @import("../../../kern/kern_time.zig");
const prf: type = @import("../../../kern/subr_prf.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");

/// I/O ports: index register, then data register.
const IO_RTC: u16 = 0x70;

// MC146818 registers (FreeBSD's sys/dev/mc146818/mc146818reg.h).
const MC_SEC: u8 = 0x00;
const MC_MIN: u8 = 0x02;
const MC_HOUR: u8 = 0x04;
const MC_DOM: u8 = 0x07;
const MC_MONTH: u8 = 0x08;
const MC_YEAR: u8 = 0x09;
const MC_REGA: u8 = 0x0a;
const MC_REGB: u8 = 0x0b;
const MC_CENTURY: u8 = 0x32; // the PC/AT century byte

const MC_REGA_UIP: u8 = 0x80; // update in progress
const MC_REGB_BINARY: u8 = 0x04; // binary (not BCD) data mode
const MC_REGB_24HR: u8 = 0x02; // 24-hour mode
const MC_HOUR_PM: u8 = 0x80; // PM flag in 12-hour mode

const dev: subr_bus.Device = .{
    .name = "atrtc",
    .desc = "AT realtime clock",
    .parent = "isa0",
};

fn rtcin(reg: u8) u8 {
    // Bit 7 of the index port gates NMI; leave it clear (NMI enabled).
    bus_space.write1(.io, IO_RTC, 0, reg);
    return bus_space.read1(.io, IO_RTC, 1);
}

fn bcd2bin(v: u8) u8 {
    return (v >> 4) * 10 + (v & 0x0f);
}

const Raw: type = struct { sec: u8, min: u8, hour: u8, day: u8, mon: u8, year: u8, cent: u8 };

fn readRaw() Raw {
    // Wait for any update cycle to finish so the fields are coherent.
    var spins: u32 = 0;
    while ((rtcin(MC_REGA) & MC_REGA_UIP) != 0 and spins < 1_000_000) : (spins += 1) {}
    return .{
        .sec = rtcin(MC_SEC),
        .min = rtcin(MC_MIN),
        .hour = rtcin(MC_HOUR),
        .day = rtcin(MC_DOM),
        .mon = rtcin(MC_MONTH),
        .year = rtcin(MC_YEAR),
        .cent = rtcin(MC_CENTURY),
    };
}

fn rawEql(a: Raw, b: Raw) bool {
    return a.sec == b.sec and a.min == b.min and a.hour == b.hour and
        a.day == b.day and a.mon == b.mon and a.year == b.year and a.cent == b.cent;
}

/// Read the clock as seconds since the epoch, or null when it holds garbage.
fn gettime() ?i64 {
    // Read until two consecutive reads agree, so a rollover between fields
    // (23:59:59 -> 00:00:00) cannot produce a mixed time.
    var t: Raw = readRaw();
    var tries: u32 = 0;
    while (tries < 8) : (tries += 1) {
        const again: Raw = readRaw();
        if (rawEql(t, again)) {
            break;
        }
        t = again;
    }

    const regb: u8 = rtcin(MC_REGB);
    const binary: bool = (regb & MC_REGB_BINARY) != 0;
    const pm: bool = (t.hour & MC_HOUR_PM) != 0;
    var hour: u8 = t.hour & ~MC_HOUR_PM;
    var cent: u8 = t.cent;
    var sec: u8 = t.sec;
    var min: u8 = t.min;
    var day: u8 = t.day;
    var mon: u8 = t.mon;
    var year: u8 = t.year;
    if (!binary) {
        sec = bcd2bin(sec);
        min = bcd2bin(min);
        hour = bcd2bin(hour);
        day = bcd2bin(day);
        mon = bcd2bin(mon);
        year = bcd2bin(year);
        cent = bcd2bin(cent);
    }
    if ((regb & MC_REGB_24HR) == 0) {
        hour %= 12;
        if (pm) {
            hour += 12;
        }
    }
    // Machines without a century byte read 0 or garbage there; assume the
    // 2000s, as FreeBSD's POSIX year window does.
    const century: u32 = if (cent >= 19 and cent <= 21) cent else 20;

    return subr_clock.toEpoch(.{
        .year = century * 100 + year,
        .mon = mon,
        .day = day,
        .hour = hour,
        .min = min,
        .sec = sec,
    });
}

fn atrtcAttach(_: ?*const anyopaque) callconv(.c) void {
    subr_bus.announce(&dev, " port 0x70-0x71 irq 8", .{});
    if (gettime()) |now| {
        kern_time.setBoottime(now);
        if (prf.bootverbose) {
            var buf: [subr_clock.TIME_LEN]u8 = undefined;
            subr_bus.device_printf(&dev, "time of day %s\n", .{subr_clock.formatTime(now, &buf)});
        }
    } else {
        prf.printLine("WARNING: invalid time in real-time clock; using the default");
    }
}

comptime {
    sysinit.SYSINIT("sysinit_atrtc", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_SECOND, atrtcAttach, null);
}
