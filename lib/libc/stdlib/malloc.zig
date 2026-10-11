// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The C heap.
//
// This is the Zig counterpart of NetBSD's lib/libc/stdlib/malloc.c, reduced to
// a first-fit allocator over sbrk(). Free blocks are kept on a singly linked
// list with the node stored in the block itself (no coalescing yet); a request
// that finds no fit grows the break with morecore.

const syscall: type = @import("../sys/syscall.zig");

/// Data alignment (and minimum header spacing).
const ALIGN: usize = 16;

/// Bytes of bookkeeping before every allocation: the block size, plus padding
/// to keep the returned pointer 16-byte aligned.
const HDR: usize = 16;

/// A free block. `size` is the whole block, header included; `next` links the
/// free list.
const FreeNode: type = extern struct {
    size: usize,
    next: ?*FreeNode,
};

var free_head: ?*FreeNode = null;
var brk_cur: u64 = 0;
var brk_ready: bool = false;

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Grow the break by at least `min` bytes and add the new region to the free
/// list. Returns false when the break cannot be moved.
fn morecore(min: usize) bool {
    const chunk: usize = if (min > (1 << 16)) alignUp(min, 4096) else (1 << 16);

    if (!brk_ready) {
        brk_cur = @intCast(syscall.brkRaw(0));
        brk_ready = true;
    }
    const target: u64 = brk_cur + chunk;
    const got: i64 = syscall.brkRaw(target);
    if (got < 0) {
        return false;
    }
    const newbrk: u64 = @intCast(got);
    const base: *FreeNode = @ptrFromInt(brk_cur);
    base.size = @intCast(newbrk - brk_cur);
    base.next = free_head;
    free_head = base;
    brk_cur = newbrk;
    return true;
}

/// Allocate `size` bytes.
pub fn malloc(size: usize) ?*anyopaque {
    const need: usize = alignUp(size, ALIGN) + HDR;

    var prev: ?*FreeNode = null;
    var cur: ?*FreeNode = free_head;
    while (cur) |node| {
        if (node.size >= need) {
            if (prev) |p| {
                p.next = node.next;
            } else {
                free_head = node.next;
            }
            return @ptrFromInt(@intFromPtr(node) + HDR);
        }
        prev = node;
        cur = node.next;
    }

    if (!morecore(need)) {
        return null;
    }
    return malloc(size);
}

/// Release memory returned by malloc().
pub fn free(ptr: ?*anyopaque) void {
    const raw: *anyopaque = ptr orelse return;
    const node: *FreeNode = @ptrFromInt(@intFromPtr(raw) - HDR);
    node.next = free_head;
    free_head = node;
}

/// Allocate `size` bytes zeroed.
pub fn calloc(n: usize, size: usize) ?*anyopaque {
    const total: usize = n * size;
    const p: *anyopaque = malloc(total) orelse return null;
    const bytes: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        bytes[i] = 0;
    }
    return p;
}
