// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Intel Secure Key RNG (RDRAND) entropy source.
//
// The counterpart of FreeBSD's sys/dev/random/ivy.c: an x86-only source that
// registers with the machine-independent generator (randomdev.zig) when the
// CPU has RDRAND. Like ivy.c, which FreeBSD lists only in conf/files.x86, it
// is pulled in by the x86 ports' manifest (arch/amd64/conf/files.zig), never
// by machine-independent code.

const arch: type = @import("../../arch/arch.zig");
const randomdev: type = @import("randomdev.zig");
const prf: type = @import("../../kern/subr_prf.zig");
const sysinit: type = @import("../../sys/sysinit.zig");

const CPUID2_RDRAND: u32 = 1 << 30;

/// One RDRAND value, or null when the instruction reports failure (it may,
/// transiently, when the hardware generator is drained).
fn rdrand() ?u64 {
    var v: u64 = undefined;
    var ok: u8 = undefined;
    asm volatile (
        \\ rdrand %[v]
        \\ setc %[ok]
        : [v] "=r" (v),
          [ok] "=r" (ok),
    );
    return if (ok != 0) v else null;
}

fn random_ivy_read(buf: []u8) usize {
    var n: usize = 0;
    while (n + 8 <= buf.len) {
        var v: u64 = undefined;
        var tries: usize = 0;
        while (tries < 10) : (tries += 1) {
            v = rdrand() orelse continue;
            break;
        } else return n;
        var k: usize = 0;
        while (k < 8) : (k += 1) buf[n + k] = @truncate(v >> @intCast(k * 8));
        n += 8;
    }
    return n;
}

const random_ivy: randomdev.Source = .{
    .ident = "Intel Secure Key RNG",
    .read = random_ivy_read,
};

fn rdrandAttach(_: ?*const anyopaque) callconv(.c) void {
    if ((arch.cpu.cpuid(1, 0).ecx & CPUID2_RDRAND) == 0) return;
    randomdev.random_source_register(&random_ivy);
    if (prf.bootverbose) prf.printf("random: registering fast source %s\n", .{random_ivy.ident});
}

comptime {
    sysinit.SYSINIT("sysinit_rdrand", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_FIRST, rdrandAttach, null);
}
