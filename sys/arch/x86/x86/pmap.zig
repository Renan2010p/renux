// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// x86-64 pmap implementation.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/x86/pmap.c. A page map
// is identified by the physical address of its top-level (PML4) table, which is
// what CR3 holds. The kernel lives in the higher half (PML4 slots 256..511) and
// is shared by every page map; the lower half is the process's own user space.
//
// Page tables are reached through the higher-half direct map offset supplied by
// the bootloader.

const pte: type = @import("../include/pte.zig");
const iface: type = @import("../include/pmap.zig");
const uvm_page: type = @import("../../../uvm/uvm_page.zig");
const param: type = @import("../../../sys/param.zig");

pub const Prot: type = iface.Prot;

/// A page map: the physical address of a top-level (PML4) table.
pub const Pmap: type = u64;

const INDEX_MASK: u64 = 0x1ff;

/// First PML4 slot belonging to the kernel half.
const KERNEL_PML4_START: usize = 256;

/// Number of PML4 slots.
const PML4_SLOTS: usize = 512;

var hhdm: u64 = 0;
var kernel_pmap: Pmap = 0;

/// Prepare the pmap with the direct-map offset, and remember the boot page map
/// as the kernel's.
pub fn bootstrap(offset: u64) void {
    hhdm = offset;
    kernel_pmap = readCr3() & pte.FRAME_MASK;
}

/// The kernel's page map (the one the bootloader installed).
pub fn kernelPmap() Pmap {
    return kernel_pmap;
}

/// The page map currently loaded on this CPU.
pub fn current() Pmap {
    return readCr3() & pte.FRAME_MASK;
}

/// Read CR3.
fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> u64),
    );
}

/// Load `p` into CR3.
pub fn activate(p: Pmap) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (p),
        : .{ .memory = true });
}

/// Virtual address at which a page table page is reachable via the direct map.
fn table(pa: u64) [*]u64 {
    return @ptrFromInt((pa & pte.FRAME_MASK) + hhdm);
}

/// Create a page map with the kernel half shared and an empty user half.
pub fn create() ?Pmap {
    const pa: u64 = uvm_page.physalloc() orelse return null; // zeroed
    const dst: [*]u64 = table(pa);
    const src: [*]u64 = table(kernel_pmap);
    var i: usize = KERNEL_PML4_START;
    while (i < PML4_SLOTS) : (i += 1) {
        dst[i] = src[i];
    }
    return pa;
}

fn flagsFor(prot: Prot) u64 {
    return switch (prot) {
        .kernel_rw => pte.P | pte.RW | pte.NX,
        .kernel_ro => pte.P | pte.NX,
        .kernel_rx => pte.P,
        .user_rw => pte.P | pte.RW | pte.US | pte.NX,
        .user_ro => pte.P | pte.US | pte.NX,
        .user_rx => pte.P | pte.US,
    };
}

fn index(va: u64, comptime shift: u6) usize {
    return @intCast((va >> shift) & INDEX_MASK);
}

/// Return the next-level table for `entry`, allocating and linking one if the
/// entry is not present. Intermediate tables are marked user-accessible; a user
/// mapping still requires the US bit at the leaf, so kernel mappings stay
/// unreachable from ring 3.
fn descend(parent: [*]u64, i: usize) ?[*]u64 {
    var entry: u64 = parent[i];
    if ((entry & pte.P) == 0) {
        const child = uvm_page.physalloc() orelse return null;
        entry = child | pte.P | pte.RW | pte.US;
        parent[i] = entry;
    }
    return table(entry);
}

/// Install a leaf mapping with raw PTE flags.
fn install(p: Pmap, va: u64, pa: u64, flags: u64) void {
    const pml4 = table(p);
    const pdp = descend(pml4, index(va, pte.L4_SHIFT)) orelse return;
    const pd = descend(pdp, index(va, pte.L3_SHIFT)) orelse return;
    const pt = descend(pd, index(va, pte.L2_SHIFT)) orelse return;
    pt[index(va, pte.L1_SHIFT)] = (pa & pte.FRAME_MASK) | flags;

    if (p == current()) {
        asm volatile ("invlpg (%[p])"
            :
            : [p] "r" (va),
            : .{ .memory = true });
    }
}

/// Install a leaf mapping `va` -> `pa` in page map `p`.
pub fn map(p: Pmap, va: u64, pa: u64, prot: Prot) void {
    install(p, va, pa, flagsFor(prot));
}

/// Duplicate the user half of `src` into `dst` (fork): every present 4 KiB user
/// page is copied to a fresh physical page.
pub fn copyUser(dst: Pmap, src: Pmap, hhdm_offset: u64) void {
    const pml4 = table(src);
    var idx4: usize = 0;
    while (idx4 < KERNEL_PML4_START) : (idx4 += 1) {
        const e4: u64 = pml4[idx4];
        if ((e4 & pte.P) == 0) continue;
        const pdp = table(e4);
        var idx3: usize = 0;
        while (idx3 < INDEX_MASK + 1) : (idx3 += 1) {
            const e3: u64 = pdp[idx3];
            if ((e3 & pte.P) == 0 or (e3 & pte.PS) != 0) continue;
            const pd = table(e3);
            var idx2: usize = 0;
            while (idx2 < INDEX_MASK + 1) : (idx2 += 1) {
                const e2: u64 = pd[idx2];
                if ((e2 & pte.P) == 0 or (e2 & pte.PS) != 0) continue;
                const pt = table(e2);
                var idx1: usize = 0;
                while (idx1 < INDEX_MASK + 1) : (idx1 += 1) {
                    const e1: u64 = pt[idx1];
                    if ((e1 & pte.P) == 0) continue;

                    const dst_pa: u64 = uvm_page.physalloc() orelse return;
                    const s: [*]const u8 = @ptrFromInt((e1 & pte.FRAME_MASK) + hhdm_offset);
                    const d: [*]u8 = @ptrFromInt(dst_pa + hhdm_offset);
                    var k: usize = 0;
                    while (k < param.PAGE_SIZE) : (k += 1) {
                        d[k] = s[k];
                    }

                    const va: u64 = (@as(u64, idx4) << pte.L4_SHIFT) |
                        (@as(u64, idx3) << pte.L3_SHIFT) |
                        (@as(u64, idx2) << pte.L2_SHIFT) |
                        (@as(u64, idx1) << pte.L1_SHIFT);
                    install(dst, va, dst_pa, (e1 & 0xfff) | (e1 & pte.NX));
                }
            }
        }
    }
}

/// Map a kernel page in the kernel page map.
pub fn kenterPa(va: u64, pa: u64, prot: Prot) void {
    map(kernel_pmap, va, pa, prot);
}

/// Map a user page in page map `p`.
pub fn enterUser(p: Pmap, va: u64, pa: u64, prot: Prot) void {
    map(p, va, pa, prot);
}

/// Translate `va` to a physical address in page map `p`, or null if unmapped.
pub fn extract(p: Pmap, va: u64) ?u64 {
    const pml4 = table(p);
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
