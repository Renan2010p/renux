// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// sysctl(2).
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_sysctl.c, reduced to
// the MIBs a FreeBSD userland reads while starting up (getpagesizes, uname,
// errno strings, ...). The FreeBSD system call and MIB numbering are used, and
// the OID name table below serves sysctlbyname(3) through CTL_SYSCTL_NAME2OID.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");

const CTL_SYSCTL: u64 = 0;
const CTL_KERN: u64 = 1;
const CTL_HW: u64 = 6;
const CTL_SYSCTL_NAME2OID: u64 = 3;

const KERN_OSTYPE: u64 = 1;
const KERN_OSRELEASE: u64 = 2;
const KERN_OSREV: u64 = 3;
const KERN_VERSION: u64 = 4;
const KERN_MAXPROC: u64 = 6;
const KERN_MAXFILES: u64 = 7;
const KERN_ARGMAX: u64 = 8;
const KERN_HOSTNAME: u64 = 10;
const KERN_BOOTTIME: u64 = 21;
const KERN_OSRELDATE: u64 = 24;
const KERN_USRSTACK: u64 = 33;

const HW_MACHINE: u64 = 1;
const HW_MODEL: u64 = 2;
const HW_NCPU: u64 = 3;
const HW_BYTEORDER: u64 = 4;
const HW_PHYSMEM: u64 = 5;
const HW_USERMEM: u64 = 6;
const HW_PAGESIZE: u64 = 7;
const HW_MACHINE_ARCH: u64 = 11;
const HW_REALMEM: u64 = 12;

/// Our own OID for hw.pagesizes (FreeBSD assigns it dynamically). The array is
/// one size_t: the base page size.
const HW_PAGESIZES: u64 = 1000;

/// Reported OS release. Renux speaks the FreeBSD 14.5 ABI, so userland feature
/// checks see a compatible release date.
const OSRELDATE: i64 = 1405000;
const OSTYPE: []const u8 = "Renux";
const OSRELEASE: []const u8 = "14.5-RELEASE";
const VERSION: []const u8 = "Renux 0.1 (FreeBSD 14.5 userland ABI)";

// -- user memory access (the kernel runs in the process's address space) -----

fn getU64(p: u64) u64 {
    const q: *align(1) const u64 = @ptrFromInt(p);
    return q.*;
}

fn putU64(p: u64, v: u64) void {
    const q: *align(1) u64 = @ptrFromInt(p);
    q.* = v;
}

fn getI32(p: u64) i32 {
    const q: *align(1) const i32 = @ptrFromInt(p);
    return q.*;
}

fn putI32(p: u64, v: i32) void {
    const q: *align(1) i32 = @ptrFromInt(p);
    q.* = v;
}

fn putBytes(dst: u64, src: []const u8) void {
    const d: [*]u8 = @ptrFromInt(dst);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        d[i] = src[i];
    }
}

// -- MIB name table (for sysctlbyname) ---------------------------------------

const NameMib: type = struct { name: []const u8, mib: []const u64 };

const name_mib = [_]NameMib{
    .{ .name = "kern.ostype", .mib = &.{ CTL_KERN, KERN_OSTYPE } },
    .{ .name = "kern.osrelease", .mib = &.{ CTL_KERN, KERN_OSRELEASE } },
    .{ .name = "kern.osreldate", .mib = &.{ CTL_KERN, KERN_OSRELDATE } },
    .{ .name = "kern.version", .mib = &.{ CTL_KERN, KERN_VERSION } },
    .{ .name = "kern.hostname", .mib = &.{ CTL_KERN, KERN_HOSTNAME } },
    .{ .name = "kern.argmax", .mib = &.{ CTL_KERN, KERN_ARGMAX } },
    .{ .name = "kern.maxproc", .mib = &.{ CTL_KERN, KERN_MAXPROC } },
    .{ .name = "kern.maxfiles", .mib = &.{ CTL_KERN, KERN_MAXFILES } },
    .{ .name = "kern.boottime", .mib = &.{ CTL_KERN, KERN_BOOTTIME } },
    .{ .name = "kern.usrstack", .mib = &.{ CTL_KERN, KERN_USRSTACK } },
    .{ .name = "hw.machine", .mib = &.{ CTL_HW, HW_MACHINE } },
    .{ .name = "hw.machine_arch", .mib = &.{ CTL_HW, HW_MACHINE_ARCH } },
    .{ .name = "hw.model", .mib = &.{ CTL_HW, HW_MODEL } },
    .{ .name = "hw.ncpu", .mib = &.{ CTL_HW, HW_NCPU } },
    .{ .name = "hw.byteorder", .mib = &.{ CTL_HW, HW_BYTEORDER } },
    .{ .name = "hw.pagesize", .mib = &.{ CTL_HW, HW_PAGESIZE } },
    .{ .name = "hw.pagesizes", .mib = &.{ CTL_HW, HW_PAGESIZES } },
    .{ .name = "hw.physmem", .mib = &.{ CTL_HW, HW_PHYSMEM } },
    .{ .name = "hw.usermem", .mib = &.{ CTL_HW, HW_USERMEM } },
    .{ .name = "hw.realmem", .mib = &.{ CTL_HW, HW_REALMEM } },
};

/// Look up a "a.b.c" name in the OID table.
fn lookupName(name: []const u8) ?[]const u64 {
    for (name_mib) |entry| {
        var m: usize = 0;
        var eq: bool = true;
        while (m < entry.name.len) : (m += 1) {
            if (m >= name.len or name[m] != entry.name[m]) {
                eq = false;
                break;
            }
        }
        if (eq) {
            return entry.mib;
        }
    }
    return null;
}

/// Handle CTL_SYSCTL/CTL_SYSCTL_NAME2OID: translate a "a.b.c" name to a MIB.
fn nameToOid(name_ptr: u64, name_len: u64, oldp: u64, oldlenp: u64) u64 {
    if (name_ptr == 0) {
        return sys.signed(-errno.EINVAL);
    }
    const n: usize = if (name_len > param.MAXPATHLEN) param.MAXPATHLEN else @intCast(name_len);
    const np: [*]const u8 = @ptrFromInt(name_ptr);
    const name = np[0..n];

    const mib = lookupName(name) orelse return sys.signed(-errno.ENOENT);
    const bytes: u64 = mib.len * 4;
    if (oldp == 0) {
        putU64(oldlenp, bytes);
        return 0;
    }
    if (getU64(oldlenp) < bytes) {
        return sys.signed(-errno.ENOMEM);
    }
    var k: usize = 0;
    while (k < mib.len) : (k += 1) {
        putI32(oldp + k * 4, @intCast(mib[k]));
    }
    putU64(oldlenp, bytes);
    return 0;
}

/// Copy `data` out to the caller (SysV sysctl semantics).
fn report(oldp: u64, oldlenp: u64, data: []const u8) u64 {
    if (oldp == 0) {
        putU64(oldlenp, data.len);
        return 0;
    }
    const have: u64 = getU64(oldlenp);
    const n: usize = if (have < data.len) @intCast(have) else data.len;
    putBytes(oldp, data[0..n]);
    putU64(oldlenp, n);
    return 0;
}

/// Copy a 4-byte int out.
fn reportInt(oldp: u64, oldlenp: u64, v: i32) u64 {
    var b: [4]u8 = undefined;
    b[0] = @truncate(@as(u32, @bitCast(v)));
    b[1] = @truncate(@as(u32, @bitCast(v)) >> 8);
    b[2] = @truncate(@as(u32, @bitCast(v)) >> 16);
    b[3] = @truncate(@as(u32, @bitCast(v)) >> 24);
    return report(oldp, oldlenp, &b);
}

/// Copy a 8-byte long out.
fn reportLong(oldp: u64, oldlenp: u64, v: i64) u64 {
    var b: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        b[i] = @truncate(@as(u64, @bitCast(v)) >> @intCast(i * 8));
    }
    return report(oldp, oldlenp, &b);
}

/// Dispatch a MIB to its value.
fn query(mib: []const u64, oldp: u64, oldlenp: u64) u64 {
    const ctl: u64 = mib[0];
    const id: u64 = if (mib.len >= 2) mib[1] else 0;

    switch (ctl) {
        CTL_KERN => switch (id) {
            KERN_OSTYPE => return report(oldp, oldlenp, OSTYPE ++ "\x00"),
            KERN_OSRELEASE => return report(oldp, oldlenp, OSRELEASE ++ "\x00"),
            KERN_VERSION => return report(oldp, oldlenp, VERSION ++ "\x00"),
            KERN_OSREV => return reportInt(oldp, oldlenp, @intCast(OSRELDATE)),
            KERN_OSRELDATE => return reportInt(oldp, oldlenp, @intCast(OSRELDATE)),
            KERN_HOSTNAME => return report(oldp, oldlenp, "renux\x00"),
            KERN_ARGMAX => return reportInt(oldp, oldlenp, 262144),
            KERN_MAXPROC => return reportInt(oldp, oldlenp, 16),
            KERN_MAXFILES => return reportInt(oldp, oldlenp, 64),
            KERN_BOOTTIME => return reportLong(oldp, oldlenp, 0),
            KERN_USRSTACK => return reportLong(oldp, oldlenp, @intCast(arch.vmparam.USER_STACK_TOP)),
            else => return sys.signed(-errno.ENOENT),
        },
        CTL_HW => switch (id) {
            HW_MACHINE => return report(oldp, oldlenp, "amd64\x00"),
            HW_MACHINE_ARCH => return report(oldp, oldlenp, "amd64\x00"),
            HW_MODEL => return report(oldp, oldlenp, "Renux\x00"),
            HW_NCPU => return reportInt(oldp, oldlenp, 1),
            HW_BYTEORDER => return reportInt(oldp, oldlenp, 1234),
            HW_PAGESIZE => return reportInt(oldp, oldlenp, @intCast(param.PAGE_SIZE)),
            HW_PAGESIZES => {
                var b: [8]u8 = undefined;
                var i: usize = 0;
                while (i < 8) : (i += 1) {
                    b[i] = @truncate(param.PAGE_SIZE >> @intCast(i * 8));
                }
                return report(oldp, oldlenp, &b);
            },
            HW_PHYSMEM, HW_USERMEM, HW_REALMEM => return reportLong(oldp, oldlenp, 512 * 1024 * 1024),
            else => return sys.signed(-errno.ENOENT),
        },
        else => return sys.signed(-errno.ENOENT),
    }
}

/// sysctl(2)/__sysctl(2): read or change kernel state.
pub fn sysSysctl(args: [sys.MAXARGS]u64) u64 {
    const name_ptr: u64 = args[0];
    const namelen: u64 = args[1];
    const oldp: u64 = args[2];
    const oldlenp: u64 = args[3];
    const newp: u64 = args[4];
    const newlen: u64 = args[5];

    if (namelen == 0 or namelen > 24 or name_ptr == 0) {
        return sys.signed(-errno.EINVAL);
    }

    // The MIB is an array of int.
    var mib: [24]u64 = undefined;
    var i: usize = 0;
    while (i < namelen) : (i += 1) {
        const raw: i32 = getI32(name_ptr + i * 4);
        mib[i] = @intCast(@as(u32, @bitCast(raw)));
    }

    if (mib[0] == CTL_SYSCTL) {
        if (namelen == 2 and mib[1] == CTL_SYSCTL_NAME2OID) {
            return nameToOid(newp, newlen, oldp, oldlenp);
        }
        return sys.signed(-errno.EINVAL);
    }

    return query(mib[0..@intCast(namelen)], oldp, oldlenp);
}

/// __sysctlbyname(2): resolve a "a.b.c" name and query it (sysctlbyname(3)).
pub fn sysSysctlbyname(args: [sys.MAXARGS]u64) u64 {
    const name_ptr: u64 = args[0];
    const name_len: u64 = args[1];
    const oldp: u64 = args[2];
    const oldlenp: u64 = args[3];

    if (name_ptr == 0) {
        return sys.signed(-errno.EINVAL);
    }
    const n: usize = if (name_len > param.MAXPATHLEN) param.MAXPATHLEN else @intCast(name_len);
    const np: [*]const u8 = @ptrFromInt(name_ptr);
    const mib = lookupName(np[0..n]) orelse return sys.signed(-errno.ENOENT);
    return query(mib, oldp, oldlenp);
}
