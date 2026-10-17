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
//
// Two kinds of pages hang off a page map:
//
//   - its own page-table pages, recorded in the pmap's arena and freed with
//     it (destroy);
//   - the user pages its leaf entries map. These are counted (vm_page.ref):
//     copy-on-write fork maps one page in two page maps, and a page is
//     freed when its last mapping goes. Device memory is mapped UNMANAGED
//     and never counted or freed.

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

/// Per-pmap record of the page-table pages of the pmap (its top level and
/// every table below), which destroy() frees. The shared kernel half is
/// never recorded. This mirrors FreeBSD's pmap_release(), which frees only
/// the pmap's own pages and clears the shared kernel entries.
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
        const blk_pa: u64 = (vm_page.physalloc() orelse return).int();
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
            vm_page.physfree(vm_page.PAddr.fromInt(blk.pages[k]));
        }
        const nx: ?*Block = blk.next;
        vm_page.physfree(vm_page.PAddr.fromInt(@intFromPtr(blk) - hhdm));
        b = nx;
    }
    a.pmap = 0;
    a.head = null;
    a.n = 0;
}

/// A zeroed page-table page for `pmap`, recorded so destroy() frees it.
fn allocTable(pmap: Pmap) ?u64 {
    const pa: u64 = (vm_page.physalloc() orelse return null).int();
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
    const pa: u64 = (vm_page.physalloc() orelse return null).int(); // zeroed
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
        .user_rwx => pte.P | pte.RW | pte.US,
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
        const child: u64 = allocTable(owner) orelse return null;
        entry = child | pte.P | pte.RW | pte.US;
        parent[i] = entry;
    }
    return table(entry);
}

/// Flush the TLB entry for `va` when `p` is the loaded page map.
fn invalidate(p: Pmap, va: u64) void {
    if (p != current()) return;
    asm volatile ("invlpg (%[p])"
        :
        : [p] "r" (va),
        : .{ .memory = true });
}

/// Flush the whole TLB when `p` is the loaded page map (after changing
/// many entries).
fn invalidateAll(p: Pmap) void {
    if (p == current()) activate(p);
}

/// Drop the page a leaf entry maps, unless it is device memory.
fn releaseLeaf(entry: u64) void {
    if ((entry & pte.P) == 0 or (entry & pte.UNMANAGED) != 0) return;
    vm_page.unref(vm_page.PAddr.fromInt(entry & pte.FRAME_MASK));
}

/// Install a leaf mapping with raw PTE flags. A page it replaces loses that
/// mapping.
fn install(p: Pmap, va: u64, pa: u64, flags: u64) void {
    const pml4 = table(p);
    const pdp = descend(p, pml4, index(va, pte.L4_SHIFT)) orelse return;
    const pd = descend(p, pdp, index(va, pte.L3_SHIFT)) orelse return;
    const pt = descend(p, pd, index(va, pte.L2_SHIFT)) orelse return;
    const slot: *u64 = &pt[index(va, pte.L1_SHIFT)];
    const old: u64 = slot.*;
    slot.* = (pa & pte.FRAME_MASK) | flags;
    if ((old & pte.P) != 0 and (old & pte.FRAME_MASK) != (pa & pte.FRAME_MASK)) releaseLeaf(old);
    invalidate(p, va);
}

/// The leaf entry for `va` in `p`, or null when no page table covers it.
fn leafSlot(p: Pmap, va: u64) ?*u64 {
    const e4: u64 = table(p)[index(va, pte.L4_SHIFT)];
    if ((e4 & pte.P) == 0) return null;
    const e3: u64 = table(e4)[index(va, pte.L3_SHIFT)];
    if ((e3 & pte.P) == 0 or (e3 & pte.PS) != 0) return null;
    const e2: u64 = table(e3)[index(va, pte.L2_SHIFT)];
    if ((e2 & pte.P) == 0 or (e2 & pte.PS) != 0) return null;
    return &table(e2)[index(va, pte.L1_SHIFT)];
}

/// Call `visit(ctx, va, slot)` for every present leaf entry of `p` in
/// [start, end), skipping quickly over the address ranges no page table
/// covers.
fn eachLeaf(p: Pmap, start: u64, end: u64, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u64, *u64) void) void {
    const L2_SPAN: u64 = @as(u64, 1) << pte.L2_SHIFT; // one page table
    var va: u64 = start & ~@as(u64, param.PAGE_SIZE - 1);
    while (va < end) {
        const e4: u64 = table(p)[index(va, pte.L4_SHIFT)];
        if ((e4 & pte.P) == 0) {
            va = nextBoundary(va, pte.L4_SHIFT);
            continue;
        }
        const e3: u64 = table(e4)[index(va, pte.L3_SHIFT)];
        if ((e3 & pte.P) == 0 or (e3 & pte.PS) != 0) {
            va = nextBoundary(va, pte.L3_SHIFT);
            continue;
        }
        const e2: u64 = table(e3)[index(va, pte.L2_SHIFT)];
        if ((e2 & pte.P) == 0 or (e2 & pte.PS) != 0) {
            va = nextBoundary(va, pte.L2_SHIFT);
            continue;
        }
        const pt: [*]u64 = table(e2);
        const table_end: u64 = @min(end, (va & ~(L2_SPAN - 1)) + L2_SPAN);
        while (va < table_end) : (va += param.PAGE_SIZE) {
            const slot: *u64 = &pt[index(va, pte.L1_SHIFT)];
            if ((slot.* & pte.P) != 0) visit(ctx, va, slot);
        }
    }
}

/// The number of pages mapped in the user half of page map `p`: its
/// resident set.
pub fn residentCount(p: Pmap) u64 {
    const Visit = struct {
        fn visit(count: *u64, va: u64, slot: *u64) void {
            _ = va;
            _ = slot;
            count.* += 1;
        }
    };
    var n: u64 = 0;
    eachLeaf(p, 0, @as(u64, 1) << 47, &n, Visit.visit);
    return n;
}

/// The first address past the region of size 2^shift containing `va`.
fn nextBoundary(va: u64, comptime shift: u6) u64 {
    const span: u64 = @as(u64, 1) << shift;
    return (va & ~(span - 1)) +% span;
}

/// Install a leaf mapping `va` -> `pa` in page map `p`.
pub fn map(p: Pmap, va: u64, pa: u64, prot: Prot) void {
    install(p, va, pa, flagsFor(prot));
}

/// Unmap [start, end) in `p`, dropping each page's mapping (munmap, and
/// what a new mapping replaces).
pub fn removeRange(p: Pmap, start: u64, end: u64) void {
    const Visit = struct {
        fn visit(_: void, _: u64, slot: *u64) void {
            const old: u64 = slot.*;
            slot.* = 0;
            releaseLeaf(old);
        }
    };
    eachLeaf(p, start, end, {}, Visit.visit);
    invalidateAll(p);
}

/// Map the pages `src` has in [start, end) in `dst` too, copy-on-write
/// (fork): both page maps lose write access to a shared page, which is
/// marked COW so the first write copies it (resolveCow). Device memory is
/// simply shared.
pub fn copyRangeCow(dst: Pmap, src: Pmap, start: u64, end: u64) void {
    const Visit = struct {
        fn visit(target: Pmap, va: u64, slot: *u64) void {
            var entry: u64 = slot.*;
            if ((entry & pte.UNMANAGED) == 0) {
                if ((entry & pte.RW) != 0) {
                    entry = (entry & ~pte.RW) | pte.COW;
                    slot.* = entry;
                }
                vm_page.ref(vm_page.PAddr.fromInt(entry & pte.FRAME_MASK));
            }
            // The child starts with the page clean: only what it writes
            // itself is its to write back to a shared file mapping.
            install(target, va, entry & pte.FRAME_MASK, entry & ~(pte.FRAME_MASK | pte.D));
        }
    };
    eachLeaf(src, start, end, dst, Visit.visit);
    invalidateAll(src);
}

/// Call `visit(ctx, va, pa)` for every page in [start, end) the user has
/// written since it was mapped or last visited (the hardware's dirty bit),
/// and clear the bit (for writing a shared file mapping back to its file:
/// munmap, msync, exit).
pub fn eachDirty(p: Pmap, start: u64, end: u64, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u64, u64) void) void {
    const Ctx = struct { inner: @TypeOf(ctx) };
    const Visit = struct {
        fn leaf(c: Ctx, va: u64, slot: *u64) void {
            if ((slot.* & pte.D) == 0 or (slot.* & pte.UNMANAGED) != 0) return;
            slot.* &= ~pte.D;
            visit(c.inner, va, slot.* & pte.FRAME_MASK);
        }
    };
    eachLeaf(p, start, end, Ctx{ .inner = ctx }, Visit.leaf);
    invalidateAll(p);
}

/// Give the pages present in [start, end) the protection `prot`
/// (mprotect); with `accessible` false the user cannot reach them at all
/// (PROT_NONE). A copy-on-write page stays read-only until written.
pub fn protectRange(p: Pmap, start: u64, end: u64, prot: Prot, accessible: bool) void {
    const Ctx = struct { flags: u64, accessible: bool };
    const Visit = struct {
        fn visit(ctx: Ctx, _: u64, slot: *u64) void {
            const keep: u64 = slot.* & (pte.FRAME_MASK | pte.COW | pte.UNMANAGED | pte.A | pte.D);
            var flags: u64 = ctx.flags;
            if ((keep & pte.COW) != 0) flags &= ~pte.RW;
            if (!ctx.accessible) flags &= ~pte.US;
            slot.* = keep | flags;
        }
    };
    eachLeaf(p, start, end, Ctx{ .flags = flagsFor(prot), .accessible = accessible }, Visit.visit);
    invalidateAll(p);
}

/// Resolve a write to the copy-on-write page at `va` (FreeBSD's
/// vm_fault_cow): a page no one else maps any more just becomes writable,
/// a shared one is copied. Returns false when the page is not
/// copy-on-write (the write is not allowed).
pub fn resolveCow(p: Pmap, va: u64) bool {
    const slot: *u64 = leafSlot(p, va) orelse return false;
    const entry: u64 = slot.*;
    if ((entry & pte.P) == 0) return false;
    if ((entry & pte.RW) != 0) return true; // already resolved
    if ((entry & pte.COW) == 0) return false;
    const old: vm_page.PAddr = vm_page.PAddr.fromInt(entry & pte.FRAME_MASK);
    if (vm_page.refCount(old) == 1) {
        slot.* = (entry & ~pte.COW) | pte.RW;
        invalidate(p, va);
        return true;
    }
    const copy: vm_page.PAddr = vm_page.allocUserUninit() orelse return false;
    const s: [*]const u8 = @ptrFromInt(old.int() + hhdm);
    const d: [*]u8 = @ptrFromInt(copy.int() + hhdm);
    @memcpy(d[0..param.PAGE_SIZE], s[0..param.PAGE_SIZE]);
    slot.* = copy.int() | (entry & ~(pte.FRAME_MASK | pte.COW)) | pte.RW;
    vm_page.unref(old);
    invalidate(p, va);
    return true;
}

/// Tear down a process's address space: drop the user pages its leaf
/// entries map, then free its page tables (recorded in its arena). The
/// shared kernel half is never touched. Called when a process is reaped or
/// execs away its old image.
pub fn destroy(p: Pmap, hhdm_off: u64) void {
    _ = hhdm_off;
    const user_end: u64 = @as(u64, KERNEL_PML4_START) << pte.L4_SHIFT;
    const Visit = struct {
        fn visit(_: void, _: u64, slot: *u64) void {
            releaseLeaf(slot.*);
            slot.* = 0;
        }
    };
    eachLeaf(p, 0, user_end, {}, Visit.visit);
    arenaClose(p);
}

/// Map a kernel page in the kernel page map.
pub fn kenterPa(va: u64, pa: u64, prot: Prot) void {
    map(kernel_pmap, va, pa, prot);
}

/// Map user page `pa` (counted by vm_page.allocUser or ref) at `va` in
/// page map `p`.
pub fn enterUser(p: Pmap, va: u64, pa: u64, prot: Prot) void {
    map(p, va, pa, prot);
}

/// Kernel window for device registers mapped by mapdev(): PML4 slot 510
/// (vmparam.KERNEL_SCRATCH_BASE), which the loaders leave empty. Mapped
/// before the first process is created, it is shared by every page map.
const DEVMAP_BASE: u64 = 0xffffff0000000000;
const DEVMAP_SIZE: u64 = 1 << 30;
var devmap_next: u64 = DEVMAP_BASE;

/// Map `size` bytes of device registers at physical `pa` into the kernel,
/// uncached (FreeBSD's pmap_mapdev()). Returns the virtual address of `pa`,
/// or null when the window is full or page tables run out.
pub fn mapdev(pa: u64, size: u64) ?u64 {
    const start: u64 = pa & ~@as(u64, param.PAGE_SIZE - 1);
    const end: u64 = (pa + size + param.PAGE_SIZE - 1) & ~@as(u64, param.PAGE_SIZE - 1);
    if (devmap_next + (end - start) > DEVMAP_BASE + DEVMAP_SIZE) return null;
    const va: u64 = devmap_next;
    var off: u64 = 0;
    while (off < end - start) : (off += param.PAGE_SIZE) {
        install(kernel_pmap, va + off, start + off, pte.P | pte.RW | pte.NX | pte.PCD | pte.PWT | pte.UNMANAGED);
        if (extract(kernel_pmap, va + off) == null) return null;
    }
    devmap_next += end - start;
    return va + (pa - start);
}

/// Map device memory `pa` at `va` in page map `p`: never counted or freed.
pub fn enterDevice(p: Pmap, va: u64, pa: u64, prot: Prot) void {
    install(p, va, pa, flagsFor(prot) | pte.UNMANAGED);
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
