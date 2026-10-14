// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// CPU identification.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/amd64/identcpu.c,
// reduced to reading CPUID and printing a FreeBSD-style CPU report at boot.

const cpufunc: type = @import("../../x86/include/cpufunc.zig");
const prf: type = @import("../../../core/subr_prf.zig");
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

// Feature bit names, as FreeBSD's identcpu.c prints them with "%b".

/// CPUID.1:EDX.
const features_names: []const []const u8 = &.{
    "FPU",  "VME",   "DE",   "PSE",     "TSC",  "MSR", "PAE",  "MCE",
    "CX8",  "APIC",  "",     "SEP",     "MTRR", "PGE", "MCA",  "CMOV",
    "PAT",  "PSE36", "PN",   "CLFLUSH", "",     "DTS", "ACPI", "MMX",
    "FXSR", "SSE",   "SSE2", "SS",      "HTT",  "TM",  "IA64", "PBE",
};

/// CPUID.1:ECX.
const features2_names: []const []const u8 = &.{
    "SSE3",   "PCLMULQDQ", "DTES64",  "MON",     "DS_CPL", "VMX",    "SMX",    "EST",
    "TM2",    "SSSE3",     "CNXT-ID", "SDBG",    "FMA",    "CX16",   "xTPR",   "PDCM",
    "",       "PCID",      "DCA",     "SSE4.1",  "SSE4.2", "x2APIC", "MOVBE",  "POPCNT",
    "TSCDLT", "AESNI",     "XSAVE",   "OSXSAVE", "AVX",    "F16C",   "RDRAND", "HV",
};

/// CPUID.80000001h:EDX (the bits that are not copies of CPUID.1:EDX).
const amd_features_names: []const []const u8 = &.{
    "", "",      "",        "",        "",   "",   "",        "",
    "", "",      "",        "SYSCALL", "",   "",   "",        "",
    "", "",      "",        "MP",      "NX", "",   "MMX+",    "",
    "", "FFXSR", "Page1GB", "RDTSCP",  "",   "LM", "3DNow!+", "3DNow!",
};

/// CPUID.80000001h:ECX.
const amd_features2_names: []const []const u8 = &.{
    "LAHF",     "CMP",  "SVM", "ExtAPIC", "CR8",    "ABM",    "SSE4A",    "MAS",
    "Prefetch", "OSVW", "IBS", "XOP",     "SKINIT", "WDT",    "",         "LWP",
    "FMA4",     "TCE",  "",    "NodeId",  "",       "TBM",    "Topology", "PCXC",
    "PNXC",     "",     "DBE", "PTSC",    "PL2I",   "MWAITX", "ADMSKX",   "",
};

/// The AMD-defined feature bits that may duplicate CPUID.1:EDX; FreeBSD masks
/// the duplicates out of "AMD Features" so only the extended bits are listed.
const AMD_DUP_MASK: u32 = 0x0183f3ff;

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

/// Measure the TSC frequency in Hz against i8254 channel 2 (the speaker
/// timer, free at this point in boot), as FreeBSD's tsc calibration does.
fn tscFreq() u64 {
    const PIT_FREQ: u64 = 1_193_182;
    const ms: u64 = 50;
    const count: u16 = @intCast(PIT_FREQ * ms / 1000);

    // Gate channel 2 on, speaker off.
    const port61: u8 = inb(0x61);
    outb(0x61, (port61 & ~@as(u8, 0x02)) | 0x01);
    // Channel 2, lobyte/hibyte, mode 0 (interrupt on terminal count).
    outb(0x43, 0xb0);
    outb(0x42, @truncate(count));
    outb(0x42, @truncate(count >> 8));

    const t0: u64 = rdtsc();
    var spins: u64 = 0;
    // OUT2 (bit 5 of port 0x61) goes high when the count expires.
    while ((inb(0x61) & 0x20) == 0) : (spins += 1) {
        if (spins > 100_000_000) {
            outb(0x61, port61);
            return 0;
        }
    }
    const t1: u64 = rdtsc();
    outb(0x61, port61);
    return (t1 - t0) * 1000 / ms;
}

/// Display family and model, extended fields folded in as FreeBSD's
/// CPUID_TO_FAMILY() and CPUID_TO_MODEL() do.
fn cpuFamily(id: u32) u32 {
    const base: u32 = (id >> 8) & 0xf;
    return if (base == 0xf) base + ((id >> 20) & 0xff) else base;
}

fn cpuModel(id: u32) u32 {
    const base: u32 = (id >> 4) & 0xf;
    const family: u32 = (id >> 8) & 0xf;
    return if (family == 0x6 or family == 0xf) base | (((id >> 16) & 0xf) << 4) else base;
}

/// Print the CPU report FreeBSD prints at boot:
///
///   CPU: QEMU Virtual CPU version 2.5+ (2793.55-MHz K8-class CPU)
///     Origin="AuthenticAMD"  Id=0x60fb1  Family=0xf  Model=0x6b  Stepping=1
///     Features=0x78bfbfd<FPU,DE,PSE,TSC,...>
///     Features2=0x80002001<SSE3,CX16,HV>
///     AMD Features=0x20100800<SYSCALL,NX,LM>
///     AMD Features2=0x1<LAHF>
///   Hypervisor: Origin = "TCGTCGTCGTCG"
fn identify(_: ?*const anyopaque) callconv(.c) void {
    var vendor: [12]u8 = undefined;
    vendorString(&vendor);

    var brand: [48]u8 = undefined;
    const have_brand: bool = brandString(&brand);

    prf.print("CPU: ");
    prf.print(if (have_brand) trim(brand[0..48]) else vendor[0..12]);
    const hz: u64 = tscFreq();
    if (hz != 0) {
        const khz: u64 = hz / 10_000; // hundredths of a MHz
        prf.printf(" (%u.", .{khz / 100});
        if (khz % 100 < 10) prf.putchar('0');
        prf.printf("%u-MHz K8-class CPU)", .{khz % 100});
    }
    prf.printLine("");

    const leaf1: cpufunc.Cpuid = cpufunc.cpuid(1, 0);
    const id: u32 = leaf1.eax;
    prf.printf("  Origin=\"%s\"  Id=%x  Family=%x  Model=%x  Stepping=%u\n", .{
        vendor[0..12], id, cpuFamily(id), cpuModel(id), id & 0xf,
    });

    prf.print("  Features=");
    prf.printBits(leaf1.edx, features_names);
    prf.printLine("");
    prf.print("  Features2=");
    prf.printBits(leaf1.ecx, features2_names);
    prf.printLine("");

    const ext_max: u32 = cpufunc.cpuid(0x80000000, 0).eax;
    if (ext_max >= 0x80000001) {
        const ext: cpufunc.Cpuid = cpufunc.cpuid(0x80000001, 0);
        prf.print("  AMD Features=");
        prf.printBits(ext.edx & ~(leaf1.edx & AMD_DUP_MASK), amd_features_names);
        prf.printLine("");
        prf.print("  AMD Features2=");
        prf.printBits(ext.ecx, amd_features2_names);
        prf.printLine("");
    }

    // A hypervisor announces itself through CPUID.1:ECX.HV and leaf
    // 0x40000000 (FreeBSD's identify_hypervisor()).
    if ((leaf1.ecx & (1 << 31)) != 0) {
        const hv: cpufunc.Cpuid = cpufunc.cpuid(0x40000000, 0);
        var name: [12]u8 = undefined;
        storeLE(name[0..4], hv.ebx);
        storeLE(name[4..8], hv.ecx);
        storeLE(name[8..12], hv.edx);
        prf.printf("Hypervisor: Origin = \"%s\"\n", .{trim(name[0..12])});
    }
}

comptime {
    sysinit.SYSINIT("sysinit_identcpu", sysinit.SI_SUB_CPU, sysinit.SI_ORDER_FIRST, identify, null);
}
