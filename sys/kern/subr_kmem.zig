// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Kernel memory allocator.
//
// This is the Zig counterpart of NetBSD's kmem(9) (sys/kern/subr_kmem.c +
// sys/sys/kmem.h), reduced to a fixed-class bucket allocator. An allocation is
// rounded up to one of a small set of size classes, and each class keeps its
// own free list. Objects are carved from 4 KiB pages obtained through
// uvm_page; a free object stores the next link in its own first bytes, so no
// side tables are needed, and every object begins with an eight-byte header
// that records its size class, which is what kmem_free() uses to find the
// right free list.
//
// Only whole pages are ever requested from the physical allocator, and no
// locking is used yet (single CPU).

const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// Bytes reserved at the start of every object for the size-class header.
pub const HEADER: usize = 8;

/// Object sizes, in bytes, header included. These must be multiples of eight
/// so that the object returned to the caller stays pointer-aligned, and the
/// largest must not exceed one page.
const CLASSES: [9]usize = .{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };

/// Head of the free list for each size class, as a virtual address; zero means
/// the list is empty.
var freelist: [CLASSES.len]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };

/// Higher-half direct map offset used to reach physical pages.
var hhdm: u64 = 0;

/// Prepare the allocator with the direct-map offset used to reach memory.
pub fn init(offset: u64) void {
    hhdm = offset;
    var i: usize = 0;
    while (i < CLASSES.len) : (i += 1) {
        freelist[i] = 0;
    }
    prf.printLine("kmem: bucket allocator, size classes 16..4096 bytes");
}

/// Index of the smallest class that can hold `total` bytes, or null when the
/// request is larger than the last class.
fn classFor(total: usize) ?usize {
    var i: usize = 0;
    while (i < CLASSES.len) : (i += 1) {
        if (CLASSES[i] >= total) {
            return i;
        }
    }
    return null;
}

/// Push the object at virtual address `obj` onto the free list of class `idx`.
fn pushFree(idx: usize, obj: usize) void {
    const node: *usize = @ptrFromInt(obj);
    node.* = freelist[idx];
    freelist[idx] = obj;
}

/// Pop one object from class `idx`, carving a fresh page when the list is
/// empty. Returns the virtual address of the object, or null when out of pages.
fn popFree(idx: usize) ?usize {
    if (freelist[idx] != 0) {
        const obj: usize = freelist[idx];
        const node: *const usize = @ptrFromInt(obj);
        freelist[idx] = node.*;
        return obj;
    }

    const size: usize = CLASSES[idx];
    const pa: u64 = uvm_page.physalloc() orelse return null;
    const base: usize = @intCast(pa + hhdm);
    const count: usize = param.PAGE_SIZE / size;

    // Link every object of the new page onto the free list.
    var k: usize = 0;
    while (k < count) : (k += 1) {
        pushFree(idx, base + k * size);
    }
    // The page holds `count` objects and none have been used yet.
    return popFree(idx);
}

/// Reserve `size` bytes of kernel memory, or null when the request cannot be
/// satisfied. The returned pointer is eight-byte aligned; the whole-class span
/// behind it belongs to the caller.
pub fn alloc(size: usize) ?*anyopaque {
    const idx: usize = classFor(size + HEADER) orelse return null;
    const obj: usize = popFree(idx) orelse return null;

    // Record the class so free() can find the right list.
    const header: *usize = @ptrFromInt(obj);
    header.* = idx;

    return @ptrFromInt(obj + HEADER);
}

/// Reserve space for one `T`, or null on failure.
pub fn allocAs(comptime T: type) ?*T {
    const raw: ?*anyopaque = alloc(@sizeOf(T));
    const ptr: *anyopaque = raw orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Release memory previously returned by alloc()/allocAs(). A null pointer is
/// ignored, as free(3) does.
pub fn free(ptr: ?*anyopaque) void {
    const p: *anyopaque = ptr orelse return;
    const obj: usize = @intFromPtr(p) - HEADER;

    const header: *const usize = @ptrFromInt(obj);
    const idx: usize = header.*;
    if (idx >= CLASSES.len) {
        return; // corrupt header; refuse to poison a free list
    }

    pushFree(idx, obj);
}

/// Release memory previously returned by allocAs().
pub fn freeAs(comptime T: type, ptr: ?*T) void {
    free(@ptrCast(ptr));
}

/// Zero `len` bytes starting at `dst`.
fn zero(dst: [*]u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dst[i] = 0;
    }
}

/// Like alloc(), but the returned memory is zeroed.
pub fn zalloc(size: usize) ?*anyopaque {
    const ptr: *anyopaque = alloc(size) orelse return null;
    const bytes: [*]u8 = @ptrCast(ptr);
    zero(bytes, size);
    return ptr;
}

/// Like allocAs(), but the returned structure is zeroed.
pub fn zallocAs(comptime T: type) ?*T {
    const ptr: ?*T = allocAs(T);
    const p: *T = ptr orelse return null;
    const bytes: [*]u8 = @ptrCast(p);
    zero(bytes, @sizeOf(T));
    return p;
}
