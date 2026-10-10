// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// x86-64 pmap implementation.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/x86/pmap.c, limited to
// what early bring-up needs. It manages the kernel's page tables: it walks the
// current top-level table (the one the bootloader installed, read from CR3) and
// installs mappings, allocating intermediate tables from the physical page
// allocator as required. Page tables are reached through the higher-half direct
// map offset supplied by the bootloader.

const pte: type = @import("../include/pte.zig");
const iface: type = @import("../include/pmap.zig");
const uvm_page: type = @import("../../../uvm/uvm_page.zig");

pub const Prot: type = iface.Prot;

const INDEX_MASK: u64 = 0x1ff;

var hhdm: u64 = 0;

/// Prepare the pmap with the direct-map offset used to reach page tables.
pub fn bootstrap(offset: u64) void {
    hhdm = offset;
}

/// Read CR3 (the physical address of the top-level page table).
fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> u64),
    );
}

/// Virtual address at which a page table page is reachable via the direct map.
fn table(pa: u64) [*]u64 {
    return @ptrFromInt((pa & pte.FRAME_MASK) + hhdm);
}

fn flagsFor(prot: Prot) u64 {
    return switch (prot) {
        .kernel_rw => pte.P | pte.RW | pte.NX,
        .kernel_ro => pte.P | pte.NX,
        .kernel_rx => pte.P,
    };
}

fn index(va: u64, comptime shift: u6) usize {
    return @intCast((va >> shift) & INDEX_MASK);
}

/// Return the next-level table for `entry`, allocating and linking one if the
/// entry is not present.
fn descend(parent: [*]u64, i: usize) ?[*]u64 {
    var entry: u64 = parent[i];
    if ((entry & pte.P) == 0) {
        const child = uvm_page.physalloc() orelse return null;
        entry = child | pte.P | pte.RW;
        parent[i] = entry;
    }
    return table(entry);
}

/// Map physical page `pa` at kernel virtual address `va`.
pub fn kenterPa(va: u64, pa: u64, prot: Prot) void {
    const pml4 = table(readCr3());
    const pdp = descend(pml4, index(va, pte.L4_SHIFT)) orelse return;
    const pd = descend(pdp, index(va, pte.L3_SHIFT)) orelse return;
    const pt = descend(pd, index(va, pte.L2_SHIFT)) orelse return;
    pt[index(va, pte.L1_SHIFT)] = (pa & pte.FRAME_MASK) | flagsFor(prot);

    asm volatile ("invlpg (%[p])"
        :
        : [p] "r" (va),
        : .{ .memory = true });
}

/// Translate `va` to a physical address, or null if it is not mapped.
pub fn extract(va: u64) ?u64 {
    const pml4 = table(readCr3());
    const e4: u64 = pml4[index(va, pte.L4_SHIFT)];
    if ((e4 & pte.P) == 0) return null;

    const pdp = table(e4);
    const e3: u64 = pdp[index(va, pte.L3_SHIFT)];
    if ((e3 & pte.P) == 0) return null;
    if ((e3 & pte.PS) != 0) {
        return (e3 & pte.FRAME_1G_MASK) | (va & 0x3fff_ffff);
    }

    const pd = table(e3);
    const e2: u64 = pd[index(va, pte.L2_SHIFT)];
    if ((e2 & pte.P) == 0) return null;
    if ((e2 & pte.PS) != 0) {
        return (e2 & pte.FRAME_2M_MASK) | (va & 0x1f_ffff);
    }

    const pt = table(e2);
    const e1: u64 = pt[index(va, pte.L1_SHIFT)];
    if ((e1 & pte.P) == 0) return null;
    return (e1 & pte.FRAME_MASK) | (va & 0xfff);
}
