// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// System parameters sized from the amount of memory.
//
// The Zig counterpart of FreeBSD's sys/kern/subr_param.c (init_param2):
// limits that FreeBSD derives from the physical memory at boot instead of
// fixing at compile time. Renux computes the open-file limits the same way,
// with the same formulas, so a program sees the values it would see on a
// FreeBSD machine with as much memory:
//
//   maxusers         memory in MB / 2, at least 32, scaled down past 384
//   maxfiles         32 open files per MB of memory (at most 64 per MB),
//                    and never less than MAXFILES
//   maxfilesperproc  90% of maxfiles
//
// They are computed once memory is known (SI_SUB_VM), and reported by
// sysctl as kern.maxusers, kern.maxfiles and kern.maxfilesperproc.

const param: type = @import("../sys/param.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const prf: type = @import("subr_prf.zig");
const vm_init: type = @import("../vm/vm_init.zig");

/// The base scale of the system, from which FreeBSD sizes several tables.
pub var maxusers: u32 = 32;
/// The most files open in the whole system at once (kern.maxfiles).
pub var maxfiles: u32 = MAXFILES_FLOOR;
/// The most files one process may have open (kern.maxfilesperproc).
pub var maxfilesperproc: u32 = MAXFILES_FLOOR / 10 * 9;

/// FreeBSD's MAXFILES, the floor of maxfiles: 40 + 32 * maxusers, with
/// maxusers at its own floor of 32.
const MAXFILES_FLOOR: u32 = 40 + 32 * 32;

/// Kilobytes in `pages` pages (FreeBSD's pgtok).
fn pagesToKib(pages: u64) u64 {
    return pages * (param.PAGE_SIZE / 1024);
}

/// Size the parameters for `physpages` pages of physical memory, as
/// FreeBSD's init_param2 does.
pub fn initParam2(physpages: u64) void {
    const kib: u64 = pagesToKib(physpages);

    var users: u64 = kib / (2 * 1024);
    if (users < 32) users = 32;
    // Past 384, maxusers grows by one per 16 MB instead of per 2 MB.
    if (users > 384) users = 384 + (users - 384) / 8;
    maxusers = @intCast(users);

    const maxfiles_floor: u64 = 40 + 32 * users;
    var files: u64 = @max(maxfiles_floor, kib / (1024 / 32));
    const files_clamp: u64 = kib / (1024 / 64);
    if (files > files_clamp) files = files_clamp;
    maxfiles = @intCast(files);
    maxfilesperproc = maxfiles / 10 * 9;
}

fn initParams(_: ?*const anyopaque) callconv(.c) void {
    initParam2(vm_init.physmem() / param.PAGE_SIZE);
    prf.log(prf.LOG_INFO, "param: maxusers %u, maxfiles %u, maxfilesperproc %u", .{ maxusers, maxfiles, maxfilesperproc });
}

comptime {
    // After the memory report (SI_ORDER_SECOND), before any process exists.
    sysinit.SYSINIT("sysinit_param", sysinit.SI_SUB_VM, sysinit.SI_ORDER_THIRD, initParams, null);
}

