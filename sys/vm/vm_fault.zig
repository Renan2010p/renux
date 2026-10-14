// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Demand-zero anonymous memory.
//
// A simplified stand-in for FreeBSD's sys/vm/vm_fault.c. mmap(2) of
// anonymous memory records the range in the process (Proc.anon) instead of
// allocating every page up front; the first touch of a page faults, and the
// fault handler maps a fresh zeroed page there and lets the instruction
// retry. Programs reserve far more than they use (libc's malloc maps 2 MiB
// arenas), so this saves both the time to zero the pages and the memory.
// There is no object/amap indirection yet.

const proc: type = @import("../sys/proc.zig");

/// Registration counter (see AnonRange.seq).
var next_seq: u64 = 1;

/// Record [start, end) of `p` as demand-zero memory. Returns false when the
/// table is full; the caller then maps the pages at once.
pub fn register(p: *proc.Proc, start: u64, end: u64, write: bool, exec: bool) bool {
    for (&p.anon) |*r| {
        if (r.end == 0) {
            r.* = .{ .start = start, .end = end, .write = write, .exec = exec, .seq = next_seq };
            next_seq += 1;
            return true;
        }
    }
    return false;
}

/// The demand-zero range of `p` containing `va`, if any. Where ranges
/// overlap the most recent one wins, as a later mmap(MAP_FIXED) replaces an
/// earlier mapping (rtld reserves a library's span PROT_NONE, then maps its
/// writable .bss over part of it).
pub fn regionFor(p: *proc.Proc, va: u64) ?proc.AnonRange {
    var best: ?proc.AnonRange = null;
    for (p.anon) |r| {
        if (r.end != 0 and va >= r.start and va < r.end) {
            if (best == null or r.seq > best.?.seq) best = r;
        }
    }
    return best;
}
