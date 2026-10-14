// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
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
const vm_page: type = @import("../../../vm/vm_page.zig");
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

/// Per-pmap record of every physical page that belongs to the pmap's address
/// space: its top level, its page tables, and all its data pages. destroy()
/// frees exactly this record -- there is no walk, so it can never touch a page
/// the pmap does not own. This mirrors FreeBSD's pmap_release(), which frees
/// only the pmap's own pages and clears the shared kernel entries.
const MAXARENA: usize = 64;
const BLOCK_PAGES: usize = 500;

const Block: type = struct {
    next: ?*Block,
    used: usize,
    pages: [BLOCK_PAGES]u64,
};

const Arena: type = struct {
    pmap: u64,
    head: ?*Block,
    n: usize,
};

var arenas: [MAXARENA]Arena = undefined;

fn arenaOf(pmap: u64) ?*Arena {
    var i: usize = 0;
    while (i < MAXARENA) : (i += 1) {
        if (arenas[i].pmap == pmap) {
            return &arenas[i];
        }
    }
    return null;
}

/// Start (or find) the arena for `pmap`.
fn arenaOpen(pmap: u64) void {
    if (arenaOf(pmap) != null) {
        return;
    }
    var i: usize = 0;
    while (i < MAXARENA) : (i += 1) {
        if (arenas[i].pmap == 0) {
            arenas[i] = .{ .pmap = pmap, .head = null, .n = 0 };
            return;
        }
    }
}

/// Record `pa` as belonging to `pmap` (a no-op for an untracked pmap, such as
/// the kernel's).
fn recordPage(pmap: u64, pa: u64) void {
    const a: *Arena = arenaOf(pmap) orelse return;
    if (a.head == null or a.head.?.used == BLOCK_PAGES) {
        const blk_pa: u64 = vm_page.physalloc() orelse return;
        const b: *Block = @ptrFromInt((blk_pa & pte.FRAME_MASK) + hhdm);
        b.next = a.head;
        b.used = 0;
        a.head = b;
    }
    const b: *Block = a.head.?;
    b.pages[b.used] = pa;
    b.used += 1;
    a.n += 1;
}

/// Free every page recorded for `pmap`, and the record's own blocks. Never
/// touches a page that was not allocated for this pmap.
fn arenaClose(pmap: u64) void {
    const a: *Arena = arenaOf(pmap) orelse return;
    var b: ?*Block = a.head;
    while (b) |blk| {
        var k: usize = 0;
        while (k < blk.used) : (k += 1) {
            vm_page.physfree(blk.pages[k]);
        }
        const nx: ?*Block = blk.next;
        vm_page.physfree(@intFromPtr(blk) - hhdm);
        b = nx;
    }
    a.pmap = 0;
    a.head = null;
    a.n = 0;
}

/// Allocate a zeroed page and record it as belonging to `pmap`. Every page in a
/// process's address space -- data and page tables -- is allocated through here.
/// Like allocPage(), but the page is not zeroed: for a copy that overwrites
/// it whole.
fn allocPageUninit(pmap: Pmap) ?u64 {
    const pa: u64 = vm_page.physallocUninit() orelse return null;
    recordPage(pmap, pa);
    return pa;
}

pub fn allocPage(pmap: Pmap) ?u64 {
    const pa: u64 = vm_page.physalloc() orelse return null;
    recordPage(pmap, pa);
    return pa;
}

/// Prepare the pmap with the direct-map offset, and remember the boot page map
/// as the kernel's.
pub fn bootstrap(offset: u64) void {
    hhdm = offset;
    kernel_pmap = readCr3() & pte.FRAME_MASK;
    var i: usize = 0;
    while (i < MAXARENA) : (i += 1) {
        arenas[i] = .{ .pmap = 0, .head = null, .n = 0 };
    }
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
    const pa: u64 = vm_page.physalloc() orelse return null; // zeroed
    const dst: [*]u64 = table(pa);
    const src: [*]u64 = table(kernel_pmap);
    var i: usize = KERNEL_PML4_START;
    while (i < PML4_SLOTS) : (i += 1) {
        dst[i] = src[i];
    }
    arenaOpen(pa);
    recordPage(pa, pa);
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
fn descend(owner: u64, parent: [*]u64, i: usize) ?[*]u64 {
    var entry: u64 = parent[i];
    if ((entry & pte.P) == 0) {
        const child: u64 = allocPage(owner) orelse return null;
        entry = child | pte.P | pte.RW | pte.US;
        parent[i] = entry;
    }
    return table(entry);
}

/// Install a leaf mapping with raw PTE flags.
fn install(p: Pmap, va: u64, pa: u64, flags: u64) void {
    const pml4 = table(p);
    const pdp = descend(p, pml4, index(va, pte.L4_SHIFT)) orelse return;
    const pd = descend(p, pdp, index(va, pte.L3_SHIFT)) orelse return;
    const pt = descend(p, pd, index(va, pte.L2_SHIFT)) orelse return;
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

                    const dst_pa: u64 = allocPageUninit(dst) orelse return;
                    const s: [*]const u8 = @ptrFromInt((e1 & pte.FRAME_MASK) + hhdm_offset);
                    const d: [*]u8 = @ptrFromInt(dst_pa + hhdm_offset);
                    @memcpy(d[0..param.PAGE_SIZE], s[0..param.PAGE_SIZE]);

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

/// Tear down a process's address space: free every page recorded for `p` (its
/// top level, its page tables and its data pages). There is no walk, so it can
/// never touch a page the pmap does not own, and the shared kernel half (which
/// is never recorded) is left alone. Called when a process is reaped or execs
/// away its old image.
pub fn destroy(p: Pmap, hhdm_off: u64) void {
    _ = hhdm_off;
    arenaClose(p);
}

/// Map a kernel page in the kernel page map.
pub fn kenterPa(va: u64, pa: u64, prot: Prot) void {
    map(kernel_pmap, va, pa, prot);}

/// Map a user page in page map `p`.
pub fn enterUser(p: Pmap, va: u64, pa: u64, prot: Prot) void {
    map(p, va, pa, prot);
}

/// The page-table entries that translate `va` in `p`, top level first (PML4,
/// PDPT, PD, PT); levels below a missing or large-page entry are 0. For fault
/// reports.
pub fn walk(p: Pmap, va: u64) [4]u64 {
    var e: [4]u64 = .{ 0, 0, 0, 0 };
    e[0] = table(p)[index(va, pte.L4_SHIFT)];
    if ((e[0] & pte.P) == 0) return e;
    e[1] = table(e[0])[index(va, pte.L3_SHIFT)];
    if ((e[1] & pte.P) == 0 or (e[1] & pte.PS) != 0) return e;
    e[2] = table(e[1])[index(va, pte.L2_SHIFT)];
    if ((e[2] & pte.P) == 0 or (e[2] & pte.PS) != 0) return e;
    e[3] = table(e[2])[index(va, pte.L1_SHIFT)];
    return e;
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
