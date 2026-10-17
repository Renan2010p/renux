// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Process address maps.
//
// The Zig counterpart of FreeBSD's sys/vm/vm_map.c. A process's user address
// space is described by a map: a sorted list of non-overlapping entries, each
// a range of pages with its protection, how a fork child inherits it, and
// where its pages come from:
//
//   anon    zero-filled pages, made on the first touch (malloc arenas, the
//           stack, .bss);
//   vnode   pages read from a file on the first touch (the program and its
//           libraries, mmap of a file). A private mapping keeps its writes
//           to itself; a shared one (MAP_SHARED) writes the pages the
//           process changed back to the file when they are unmapped, at
//           msync(2) and at exit -- which is how a linker writes its output
//           through mmap. (Unlike FreeBSD, whose pages are the file's own,
//           the file only sees the changes at those points.)
//   device  pages of a device's own memory (the framebuffer), mapped when
//           the entry is made.
//
// The map says what the address space may hold; the page tables (pmap) hold
// what is there now. A touch of a page the map allows but the page tables
// lack is a page fault, which vm_fault.zig resolves from the entry.
//
// The entries live in physically contiguous pages that grow by doubling,
// so a process may have as many as it needs.

const std: type = @import("std");
const param: type = @import("../sys/param.zig");
const vnode: type = @import("../sys/vnode.zig");
const arch: type = @import("../arch/arch.zig");
const vm_page: type = @import("vm_page.zig");
const vfs_subr: type = @import("../core/vfs_subr.zig");

/// Protection bits (FreeBSD's VM_PROT_*, the same values as PROT_*).
pub const PROT_READ: u8 = 0x1;
pub const PROT_WRITE: u8 = 0x2;
pub const PROT_EXEC: u8 = 0x4;

/// How a fork child gets an entry (minherit(2); FreeBSD's VM_INHERIT_*).
pub const Inherit: type = enum(u8) {
    /// A copy: pages are shared copy-on-write.
    copy,
    /// Not at all: the child has nothing mapped there (INHERIT_NONE).
    none,
    /// Fresh zero-filled memory (INHERIT_ZERO; libc keeps its arc4random
    /// state there so a child never repeats the parent's random stream).
    zero,
};

/// A file an entry maps.
pub const VnodeObject: type = struct {
    vp: *vnode.Vnode,
    /// File offset of the entry's first byte.
    offset: u64,
    /// File offset where the mapped bytes of the file end; the rest of the
    /// entry reads as zeros (an ELF segment's .bss, the tail of a file).
    file_end: u64,
    /// Changes go back to the file (MAP_SHARED).
    shared: bool = false,
};

/// Where an entry's pages come from.
pub const Object: type = union(enum) {
    anon,
    vnode: VnodeObject,
    device,
};

/// One range of the address space (FreeBSD's struct vm_map_entry).
pub const Entry: type = struct {
    start: u64,
    end: u64,
    prot: u8,
    inherit: Inherit = .copy,
    object: Object,

    /// The protection the page tables give the entry's pages.
    pub fn pmapProt(e: *const Entry) arch.pmap.Prot {
        const write: bool = (e.prot & PROT_WRITE) != 0;
        if ((e.prot & PROT_EXEC) != 0) return if (write) .user_rwx else .user_rx;
        return if (write) .user_rw else .user_ro;
    }
};

pub const Error: type = error{NoMemory};

/// A process's address map (FreeBSD's struct vm_map).
pub const VmMap: type = struct {
    /// Storage for the entries (physically contiguous pages), or empty.
    storage: []Entry = &.{},
    /// Entries in use, sorted by address.
    count: usize = 0,

    /// The entries, in address order.
    pub fn entries(map: *VmMap) []Entry {
        return map.storage[0..map.count];
    }
};

// -- storage -------------------------------------------------------------------

fn pagesFor(capacity: usize) u64 {
    return (capacity * @sizeOf(Entry) + param.PAGE_SIZE - 1) / param.PAGE_SIZE;
}

/// Make room for one more entry.
fn reserve(map: *VmMap) Error!void {
    if (map.count < map.storage.len) return;
    const new_capacity: usize = if (map.storage.len == 0) param.PAGE_SIZE / @sizeOf(Entry) else map.storage.len * 2;
    const pages: u64 = pagesFor(new_capacity);
    const pa: vm_page.PAddr = vm_page.physallocContig(pages) orelse return error.NoMemory;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return error.NoMemory;
    const first: [*]Entry = @ptrFromInt(pa.int() + hhdm);
    const room: []Entry = first[0 .. pages * param.PAGE_SIZE / @sizeOf(Entry)];
    @memcpy(room[0..map.count], map.storage[0..map.count]);
    freeStorage(map);
    map.storage = room;
}

fn freeStorage(map: *VmMap) void {
    if (map.storage.len == 0) return;
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
    const pa: vm_page.PAddr = vm_page.PAddr.fromInt(@intFromPtr(map.storage.ptr) - hhdm);
    vm_page.physfreeContig(pa, pagesFor(map.storage.len));
    map.storage = &.{};
}

/// Take a reference on the file behind `e`, if any (a new entry shares it).
fn holdObject(e: *const Entry) void {
    switch (e.object) {
        .vnode => |v| vfs_subr.vref(v.vp),
        else => {},
    }
}

/// Drop the reference on the file behind `e`, if any.
fn dropObject(e: *const Entry) void {
    switch (e.object) {
        .vnode => |v| vfs_subr.vrele(v.vp),
        else => {},
    }
}

/// Release every entry's file and the storage. The pages themselves belong
/// to the page tables (pmap.destroy).
pub fn deinit(map: *VmMap) void {
    for (map.entries()) |*e| dropObject(e);
    map.count = 0;
    freeStorage(map);
}

// -- lookup ----------------------------------------------------------------------

/// The index of the first entry that ends after `va`.
fn firstEndingAfter(map: *VmMap, va: u64) usize {
    var lo: usize = 0;
    var hi: usize = map.count;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        if (map.storage[mid].end <= va) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The entry containing `va`, if any.
pub fn lookup(map: *VmMap, va: u64) ?*Entry {
    const i: usize = firstEndingAfter(map, va);
    if (i < map.count and map.storage[i].start <= va) return &map.storage[i];
    return null;
}

/// True when some entry overlaps [start, end).
pub fn overlaps(map: *VmMap, start: u64, end: u64) bool {
    const i: usize = firstEndingAfter(map, start);
    return i < map.count and map.storage[i].start < end;
}

/// The lowest address at or above `hint`, aligned to `alignment`, where
/// `size` bytes fit below `limit` without touching an entry (FreeBSD's
/// vm_map_findspace). Null when there is no such hole.
pub fn findSpace(map: *VmMap, hint: u64, size: u64, alignment: u64, limit: u64) ?u64 {
    var candidate: u64 = std.mem.alignForward(u64, hint, alignment);
    var i: usize = firstEndingAfter(map, candidate);
    while (true) {
        if (candidate + size > limit or candidate + size < candidate) return null;
        if (i >= map.count or map.storage[i].start >= candidate + size) return candidate;
        candidate = std.mem.alignForward(u64, map.storage[i].end, alignment);
        i += 1;
    }
}

// -- changing the map ----------------------------------------------------------

/// The entry `e` from `va` on, as a new entry: its file offset moves with it.
fn tailFrom(e: Entry, va: u64) Entry {
    var tail: Entry = e;
    tail.start = va;
    switch (tail.object) {
        .vnode => |*v| v.offset += va - e.start,
        else => {},
    }
    return tail;
}

/// Insert `e` at index `i`, keeping the order.
fn insertAt(map: *VmMap, i: usize, e: Entry) Error!void {
    try reserve(map);
    std.mem.copyBackwards(Entry, map.storage[i + 1 .. map.count + 1], map.storage[i..map.count]);
    map.storage[i] = e;
    map.count += 1;
}

fn removeAt(map: *VmMap, i: usize) void {
    std.mem.copyForwards(Entry, map.storage[i .. map.count - 1], map.storage[i + 1 .. map.count]);
    map.count -= 1;
}

/// Make `va` the boundary between two entries, splitting the entry that
/// contains it (FreeBSD's vm_map_clip_start).
fn clip(map: *VmMap, va: u64) Error!void {
    const i: usize = firstEndingAfter(map, va);
    if (i >= map.count) return;
    const e: Entry = map.storage[i];
    if (e.start >= va) return;
    try insertAt(map, i + 1, tailFrom(e, va));
    holdObject(&map.storage[i + 1]);
    map.storage[i].end = va;
}

/// Write the pages of shared file mappings in [start, end) that the process
/// changed back to their files (msync(2); FreeBSD's vm_map_sync). Pages
/// past the end of the file are not written: a mapping does not grow its
/// file.
pub fn sync(map: *VmMap, pmap: arch.pmap.Pmap, start: u64, end: u64) void {
    var i: usize = firstEndingAfter(map, start);
    while (i < map.count and map.storage[i].start < end) : (i += 1) {
        const e: *const Entry = &map.storage[i];
        const v: VnodeObject = switch (e.object) {
            .vnode => |file| file,
            else => continue,
        };
        if (!v.shared) continue;
        var vap: vnode.Vattr = std.mem.zeroes(vnode.Vattr);
        if (v.vp.v_op.getattr(v.vp, &vap) != 0) continue;
        const Writeback = struct { vp: *vnode.Vnode, entry_start: u64, offset: u64, file_size: u64 };
        const Visit = struct {
            fn page(wb: Writeback, va: u64, pa: u64) void {
                const file_off: u64 = wb.offset + (va - wb.entry_start);
                if (file_off >= wb.file_size) return;
                const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
                const bytes: [*]const u8 = @ptrFromInt(pa + hhdm);
                const n: usize = @intCast(@min(param.PAGE_SIZE, wb.file_size - file_off));
                _ = wb.vp.v_op.write(wb.vp, file_off, bytes[0..n]);
            }
        };
        arch.pmap.eachDirty(pmap, @max(start, e.start), @min(end, e.end), Writeback{
            .vp = v.vp,
            .entry_start = e.start,
            .offset = v.offset,
            .file_size = vap.size,
        }, Visit.page);
    }
}

/// Remove [start, end) from the map and its pages from `pmap` (munmap,
/// and what a new mapping replaces; FreeBSD's vm_map_delete). Changes to a
/// shared file mapping go back to the file first.
pub fn remove(map: *VmMap, pmap: arch.pmap.Pmap, start: u64, end: u64) Error!void {
    if (start >= end) return;
    sync(map, pmap, start, end);
    try clip(map, start);
    try clip(map, end);
    // After clipping, the entries in the range start at index `i`; each
    // removal brings the next one there.
    const i: usize = firstEndingAfter(map, start);
    while (i < map.count and map.storage[i].start < end) {
        dropObject(&map.storage[i]);
        removeAt(map, i);
    }
    arch.pmap.removeRange(pmap, start, end);
}

/// Map `e`, replacing whatever the map held in its range (mmap with
/// MAP_FIXED). The map takes its own reference on a file.
pub fn insert(map: *VmMap, pmap: arch.pmap.Pmap, e: Entry) Error!void {
    try remove(map, pmap, e.start, e.end);
    try insertAt(map, firstEndingAfter(map, e.start), e);
    holdObject(&e);
}

/// Change the protection of [start, end) (mprotect(2)). Only mapped ranges
/// change; their present pages get the new protection at once.
pub fn protect(map: *VmMap, pmap: arch.pmap.Pmap, start: u64, end: u64, prot: u8) Error!void {
    try clip(map, start);
    try clip(map, end);
    var i: usize = firstEndingAfter(map, start);
    while (i < map.count and map.storage[i].start < end) : (i += 1) {
        const e: *Entry = &map.storage[i];
        e.prot = prot;
        arch.pmap.protectRange(pmap, e.start, e.end, e.pmapProt(), prot != 0);
    }
}

/// Set how a fork child inherits [start, end) (minherit(2)).
pub fn setInherit(map: *VmMap, start: u64, end: u64, inherit: Inherit) Error!void {
    try clip(map, start);
    try clip(map, end);
    var i: usize = firstEndingAfter(map, start);
    while (i < map.count and map.storage[i].start < end) : (i += 1) {
        map.storage[i].inherit = inherit;
    }
}

/// Give a fork child `dst` (with page tables `dst_pmap`) a copy of `src`
/// (FreeBSD's vmspace_fork): entries inherited as copies share their pages
/// copy-on-write, entries inherited as zero become fresh anonymous memory,
/// entries not inherited are left out.
pub fn forkCopy(dst: *VmMap, dst_pmap: arch.pmap.Pmap, src: *VmMap, src_pmap: arch.pmap.Pmap) Error!void {
    for (src.entries()) |e| {
        var copy: Entry = e;
        switch (e.inherit) {
            .none => continue,
            .zero => copy.object = .anon,
            .copy => arch.pmap.copyRangeCow(dst_pmap, src_pmap, e.start, e.end),
        }
        try insertAt(dst, dst.count, copy);
        holdObject(&copy);
    }
}
