// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Address spaces, as distinct types checked at compile time.
//
// At run time every address the kernel handles is a u64, but the kinds are not
// interchangeable and mean completely different things:
//
//   PAddr   a physical address, as the CPU sees memory with paging off;
//   KAddr   a kernel virtual address, including the HHDM direct map;
//   UAddr   a user virtual address, meaningful only in a process's own map.
//
// The classic memory-corruption bug is passing one where another is expected:
// a physical address added to the direct-map offset twice, a user pointer fed
// to a routine that dereferences it as kernel memory, a byte count handed to
// something that wanted an address. Giving each kind its own type turns those
// mistakes into compile errors and forces every conversion -- above all the
// direct map -- through one named function instead of an ad-hoc `+ hhdm`.
//
// The types cost nothing: one u64 in a struct, every method inline. The intent
// is FreeBSD's `vm_offset_t`/`vm_paddr_t` and NetBSD's `paddr_t`/`vaddr_t`,
// which have the same meaning but no compiler support; here the compiler
// enforces it.
//
// A note on what this does and does not buy. It is a *type* discipline, not a
// borrow checker: it stops an address of the wrong space from compiling, but it
// cannot track a lifetime or prove that a pointer is still valid. Zig has no
// affine types, so "use after release" is not detectable at comptime; the
// buffer handles in core/vfs_bio.zig attack that from another angle.

const std: type = @import("std");

/// A physical address: a byte offset into RAM from the CPU's point of view,
/// before paging.
pub const PAddr = struct {
    raw: u64,

    pub inline fn fromInt(x: u64) PAddr {
        return .{ .raw = x };
    }

    pub inline fn int(self: PAddr) u64 {
        return self.raw;
    }

    pub inline fn add(self: PAddr, n: u64) PAddr {
        return .{ .raw = self.raw + n };
    }

    pub inline fn sub(self: PAddr, n: u64) PAddr {
        return .{ .raw = self.raw - n };
    }

    pub inline fn eql(self: PAddr, other: PAddr) bool {
        return self.raw == other.raw;
    }

    /// Whether the address is a multiple of `a` (a power of two).
    pub inline fn isAligned(self: PAddr, comptime a: u64) bool {
        return (self.raw & (a - 1)) == 0;
    }

    /// The address rounded down to a multiple of `a` (a power of two).
    pub inline fn alignDown(self: PAddr, comptime a: u64) PAddr {
        return .{ .raw = self.raw & ~(a - 1) };
    }

    /// The kernel virtual address the direct map (HHDM) gives this page. This
    /// is the only place a physical address becomes a kernel pointer to be
    /// dereferenced; `hhdm` is the offset the bootloader reported
    /// (arch.boot.hhdmOffset()).
    pub inline fn toKern(self: PAddr, hhdm: u64) KAddr {
        return .{ .raw = self.raw + hhdm };
    }

    /// The physical address a direct-mapped kernel address names.
    pub inline fn fromKern(k: KAddr, hhdm: u64) PAddr {
        return .{ .raw = k.raw - hhdm };
    }
};

/// A kernel virtual address: an address in the kernel's own address space,
/// including the direct map of physical memory.
pub const KAddr = struct {
    raw: u64,

    pub inline fn fromInt(x: u64) KAddr {
        return .{ .raw = x };
    }

    /// The address of an existing object. The kernel runs with the direct map
    /// and its own text mapped, so this is the one safe way to turn a real
    /// pointer back into an address.
    pub inline fn of(p: anytype) KAddr {
        return .{ .raw = @intFromPtr(p) };
    }

    pub inline fn int(self: KAddr) u64 {
        return self.raw;
    }

    pub inline fn add(self: KAddr, n: u64) KAddr {
        return .{ .raw = self.raw + n };
    }

    pub inline fn eql(self: KAddr, other: KAddr) bool {
        return self.raw == other.raw;
    }

    /// A typed pointer to this address. The caller promises, at the call site,
    /// that the address names a live, correctly aligned `T`.
    pub inline fn ptr(self: KAddr, comptime T: type) *T {
        return @ptrFromInt(self.raw);
    }

    pub inline fn constPtr(self: KAddr, comptime T: type) *const T {
        return @ptrFromInt(self.raw);
    }

    /// A many-item pointer (`[*]T`), for a buffer whose length is only known
    /// at run time and is then sliced.
    pub inline fn manyPtr(self: KAddr, comptime T: type) [*]T {
        return @ptrFromInt(self.raw);
    }

    pub inline fn manyConstPtr(self: KAddr, comptime T: type) [*]const T {
        return @ptrFromInt(self.raw);
    }

    /// A pointer for memory-mapped device registers: the access is volatile so
    /// the compiler cannot fold, reorder or elide it, and is never assumed to
    /// be initialized on read.
    pub inline fn volatilePtr(self: KAddr, comptime T: type) *volatile T {
        return @ptrFromInt(self.raw);
    }

    pub inline fn slice(self: KAddr, comptime T: type, n: usize) []T {
        return self.ptr(T)[0..n];
    }

    pub inline fn constSlice(self: KAddr, comptime T: type, n: usize) []const T {
        return self.constPtr(T)[0..n];
    }

    pub inline fn toPhys(self: KAddr, hhdm: u64) PAddr {
        return PAddr.fromKern(self, hhdm);
    }
};

/// A user virtual address: an address in some process's map. The kernel may
/// only touch it after arranging that the map is active (or through the pmap's
/// user-copy routines), and never with a plain kernel dereference, since the
/// process could unmap it under the kernel at any time.
pub const UAddr = struct {
    raw: u64,

    pub inline fn fromInt(x: u64) UAddr {
        return .{ .raw = x };
    }

    pub inline fn int(self: UAddr) u64 {
        return self.raw;
    }

    pub inline fn add(self: UAddr, n: u64) UAddr {
        return .{ .raw = self.raw + n };
    }

    pub inline fn isNull(self: UAddr) bool {
        return self.raw == 0;
    }

    /// Whether the address lies in the canonical user range (below the
    /// architecturally reserved kernel half). Passing the kernel a
    /// non-canonical or kernel address was the heart of several real
    /// privilege-escalation bugs; the boundary checks it here.
    pub inline fn isCanonical(self: UAddr) bool {
        return self.raw < 0x0000_8000_0000_0000 or self.raw >= 0xffff_8000_0000_0000;
    }

    /// A pointer into the user address space, valid only while that map is
    /// active. Named `userPtr` rather than `ptr` so a kernel dereference of a
    /// user address is always visible in the source.
    pub inline fn userPtr(self: UAddr, comptime T: type) *align(1) T {
        return @ptrFromInt(self.raw);
    }
};

/// The direct-map offset: the constant the bootloader reports and every
/// physical-to-virtual conversion needs. A distinct type so a bare u64 cannot
/// be passed where the HHDM offset is wanted, and vice versa.
pub const Hhdm = struct {
    off: u64,

    pub inline fn fromInt(x: u64) Hhdm {
        return .{ .off = x };
    }

    pub inline fn int(self: Hhdm) u64 {
        return self.off;
    }

    pub inline fn kern(self: Hhdm, pa: PAddr) KAddr {
        return pa.toKern(self.off);
    }

    pub inline fn phys(self: Hhdm, k: KAddr) PAddr {
        return k.toPhys(self.off);
    }
};

// -- compile-time invariants -------------------------------------------------
//
// The types must stay exactly one word: they exist only for the compiler and
// must not change an ABI or an array layout.

comptime {
    const checks: type = @import("checks.zig");
    checks.assertSize(PAddr, @sizeOf(u64));
    checks.assertSize(KAddr, @sizeOf(u64));
    checks.assertSize(UAddr, @sizeOf(u64));
    checks.assertSize(Hhdm, @sizeOf(u64));
    checks.assertAlignOf(PAddr, @alignOf(u64));
    checks.assertAlignOf(KAddr, @alignOf(u64));
}

// -- tests (run on the host with `zig build test`) ---------------------------

const testing = @import("std").testing;

test "address kinds convert only through their named functions" {
    const p: PAddr = .fromInt(0x1000);
    const k: KAddr = p.toKern(0xffff_8000_0000_0000);
    try testing.expectEqual(@as(u64, 0xffff_8000_0000_1000), k.int());
    try testing.expectEqual(@as(u64, 0x1000), k.toPhys(0xffff_8000_0000_0000).int());
}

test "of() and int() round-trip a real pointer" {
    var x: u32 = 7;
    const a: KAddr = .of(&x);
    try testing.expectEqual(@intFromPtr(&x), a.int());
    try testing.expectEqual(@as(u32, 7), a.ptr(u32).*);
}

test "alignment helpers" {
    const p: PAddr = .fromInt(0x1234);
    try testing.expect(p.isAligned(4));
    try testing.expect(!p.isAligned(0x1000));
    try testing.expectEqual(@as(u64, 0x1000), p.alignDown(0x1000).int());
}

test "a user address is canonical below the kernel half" {
    try testing.expect(UAddr.fromInt(0x400000).isCanonical());
    try testing.expect(!UAddr.fromInt(0x0000_9000_0000_0000).isCanonical());
    try testing.expect(UAddr.fromInt(0xffff_8000_0000_0000).isCanonical());
}

test "hhdm keeps the direct-map offset in one place" {
    const h: Hhdm = .fromInt(0x4000);
    try testing.expectEqual(@as(u64, 0x14000), h.kern(PAddr.fromInt(0x10000)).int());
    try testing.expectEqual(@as(u64, 0x10000), h.phys(KAddr.fromInt(0x14000)).int());
}
