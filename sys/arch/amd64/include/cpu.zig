// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 CPU definitions.
//
// The Zig counterpart of FreeBSD's sys/amd64/include/cpu.h (<machine/cpu.h>):
// the machine-dependent services machine-independent code asks the CPU for.

const cpufunc: type = @import("../../x86/include/cpufunc.zig");

/// The CPU's fast counter, as a "bogo-time" for random harvesting
/// (FreeBSD's get_cyclecount()); here the time-stamp counter.
pub fn get_cyclecount() u64 {
    return cpufunc.rdtsc();
}
