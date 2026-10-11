// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Virtual memory system startup.
//
// This is the Zig counterpart of NetBSD's sys/uvm/uvm_init.c, reduced to what
// early bring-up needs: bootstrap the machine-dependent page map, initialise
// the physical page allocator, and load the usable physical memory described by
// the boot protocol. It registers itself with SYSINIT at SI_SUB_VM, and also
// prints the FreeBSD-style "real memory"/"avail memory" lines once the counts
// are known.

const arch: type = @import("../arch/arch.zig");
const uvm_page: type = @import("uvm_page.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("../kern/subr_prf.zig");

/// Initialise the virtual memory system.
fn uvmInit(_: ?*const anyopaque) callconv(.c) void {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;

    arch.pmap.bootstrap(hhdm);
    uvm_page.init(hhdm);

    const entries: usize = arch.boot.memmapEntryCount() orelse 0;
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        const entry: *arch.boot.MemmapEntry = arch.boot.memmapEntry(i) orelse continue;
        if (entry.type == arch.boot.MemmapEntry.USABLE) {
            uvm_page.physload(entry.base, entry.base + entry.length);
        }
    }
}

/// Total usable physical memory reported by the boot protocol.
fn totalMemory() u64 {
    var total: u64 = 0;
    const entries: usize = arch.boot.memmapEntryCount() orelse 0;
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        const entry: *arch.boot.MemmapEntry = arch.boot.memmapEntry(i) orelse continue;
        if (entry.type == arch.boot.MemmapEntry.USABLE) {
            total += entry.length;
        }
    }
    return total;
}

/// Print the memory report in FreeBSD's format:
///   real memory  = <bytes> (<MB> MB)
///   avail memory = <bytes> (<MB> MB)
fn printMemory(_: ?*const anyopaque) callconv(.c) void {
    const total: u64 = totalMemory();
    const avail: u64 = @as(u64, uvm_page.freeCount()) * param.PAGE_SIZE;

    prf.print("real memory  = ");
    prf.printDec(total);
    prf.print(" (");
    prf.printDec(total / (1024 * 1024));
    prf.printLine(" MB)");

    prf.print("avail memory = ");
    prf.printDec(avail);
    prf.print(" (");
    prf.printDec(avail / (1024 * 1024));
    prf.printLine(" MB)");
}

comptime {
    sysinit.SYSINIT("sysinit_uvm", sysinit.SI_SUB_VM, sysinit.SI_ORDER_FIRST, uvmInit, null);
    sysinit.SYSINIT("sysinit_memory", sysinit.SI_SUB_VM, sysinit.SI_ORDER_SECOND, printMemory, null);
}
