// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// CPU identification.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/amd64/identcpu.c,
// reduced to reading CPUID and printing a FreeBSD-style CPU report at boot.

const cpufunc: type = @import("../../x86/include/cpufunc.zig");
const prf: type = @import("../../../kern/subr_prf.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");

/// Store a 32-bit CPUID result little-endian into four bytes.
fn storeLE(out: []u8, value: u32) void {
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
}

/// The 12-byte vendor string ("GenuineIntel", "AuthenticAMD", ...).
fn vendorString(out: *[12]u8) void {
    const c: cpufunc.Cpuid = cpufunc.cpuid(0, 0);
    storeLE(out[0..4], c.ebx);
    storeLE(out[4..8], c.edx);
    storeLE(out[8..12], c.ecx);
}

/// The 48-byte processor brand string, when the CPU provides it.
fn brandString(out: *[48]u8) bool {
    const max: cpufunc.Cpuid = cpufunc.cpuid(0x80000000, 0);
    if (max.eax < 0x80000004) {
        return false;
    }
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const c: cpufunc.Cpuid = cpufunc.cpuid(0x80000002 + i, 0);
        storeLE(out[i * 16 ..][0..4], c.eax);
        storeLE(out[i * 16 + 4 ..][0..4], c.ebx);
        storeLE(out[i * 16 + 8 ..][0..4], c.ecx);
        storeLE(out[i * 16 + 12 ..][0..4], c.edx);
    }
    return true;
}

/// A printable slice of `s`, leading and trailing spaces and NUL padding
/// removed.
fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == 0)) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == 0)) : (end -= 1) {}
    return s[start..end];
}

fn identify(_: ?*const anyopaque) callconv(.c) void {
    var vendor: [12]u8 = undefined;
    vendorString(&vendor);

    var brand: [48]u8 = undefined;
    const have_brand: bool = brandString(&brand);

    prf.print("CPU: ");
    if (have_brand) {
        prf.printLine(trim(brand[0..48]));
    } else {
        prf.printLine(vendor[0..12]);
    }

    const leaf1: cpufunc.Cpuid = cpufunc.cpuid(1, 0);
    const eax: u32 = leaf1.eax;
    const family: u32 = (eax >> 8) & 0xf;
    const model: u32 = (eax >> 4) & 0xf;
    const stepping: u32 = eax & 0xf;

    prf.print("  Origin=\"");
    prf.print(vendor[0..12]);
    prf.print("\"  Id=");
    prf.printHexTrim(eax);
    prf.print("  Family=");
    prf.printHexTrim(family);
    prf.print("  Model=");
    prf.printHexTrim(model);
    prf.print("  Stepping=");
    prf.printHexTrim(stepping);
    prf.printLine("");

    prf.print("  Features=");
    prf.printHexTrim(leaf1.edx);
    prf.printLine("");

    prf.print("  Features2=");
    prf.printHexTrim(leaf1.ecx);
    prf.printLine("");
}

comptime {
    sysinit.SYSINIT("sysinit_identcpu", sysinit.SI_SUB_CPU, sysinit.SI_ORDER_FIRST, identify, null);
}
