// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Virtual memory system startup.
//
// This is the Zig counterpart of NetBSD's sys/uvm/uvm_init.c, reduced to what
// early bring-up needs: bootstrap the machine-dependent page map, initialise
// the physical page allocator, and load the usable physical memory described by
// the boot protocol. The NetBSD version additionally creates the kmem arena and
// the page buckets; those arrive with the rest of UVM.

const arch: type = @import("../arch/arch.zig");
const uvm_page: type = @import("uvm_page.zig");

/// Initialise the virtual memory system.
pub fn uvm_init() void {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;

    arch.pmap.bootstrap(hhdm);
    uvm_page.init(hhdm);

    const entries: usize = arch.boot.memmapEntryCount() orelse 0;
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        const entry = arch.boot.memmapEntry(i) orelse continue;
        if (entry.type == arch.boot.MemmapEntry.USABLE) {
            uvm_page.physload(entry.base, entry.base + entry.length);
        }
    }
}
