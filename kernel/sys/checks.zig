// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Compile-time layout checks.
//
// The kernel speaks several binary interfaces it does not own: the FreeBSD
// system-call ABI (struct stat, dirent, rlimit, ...), the boot protocol, and
// the register blocks of memory-mapped devices. A field added, reordered or
// widened in one of those structs changes what a program -- or a device --
// sees, and the mistake shows up only at run time, as garbage.
//
// These helpers move that failure to build time: declaring a struct's size,
// a field's offset, or its absence of hidden padding makes the compiler reject
// the change that would have broken the ABI. They are the Zig analogue of a
// static_assert on offsetof() in C.
//
// Each function is pure comptime and erases to nothing.

const std: type = @import("std");

/// The size of `T` must be `want` bytes.
pub fn assertSize(comptime T: type, comptime want: usize) void {
    if (@sizeOf(T) != want)
        @compileError(std.fmt.comptimePrint(
            "{s}: size is {d} bytes, expected {d}",
            .{ @typeName(T), @sizeOf(T), want },
        ));
}

/// The alignment of `T` must be `want` bytes.
pub fn assertAlignOf(comptime T: type, comptime want: usize) void {
    if (@alignOf(T) != want)
        @compileError(std.fmt.comptimePrint(
            "{s}: alignment is {d}, expected {d}",
            .{ @typeName(T), @alignOf(T), want },
        ));
}

/// Field `field` of struct `T` must start at byte `want`.
pub fn assertOffsetOf(comptime T: type, comptime field: []const u8, comptime want: usize) void {
    if (@offsetOf(T, field) != want)
        @compileError(std.fmt.comptimePrint(
            "{s}.{s}: offset is {d}, expected {d}",
            .{ @typeName(T), field, @offsetOf(T, field), want },
        ));
}

/// `T` must be an `extern struct`, so it keeps the C ABI layout the kernel's
/// callers and devices expect. A plain Zig struct may be reordered or padded
/// freely, which silently breaks such an interface.
pub fn assertExternStruct(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout != .@"extern")
                @compileError(std.fmt.comptimePrint(
                    "{s}: not an extern struct (layout is {s})",
                    .{ @typeName(T), @tagName(s.layout) },
                ));
        },
        else => @compileError(std.fmt.comptimePrint("{s}: not a struct", .{@typeName(T)})),
    }
}

/// No padding anywhere in `T`: its size is exactly the sum of its fields'.
/// Padding the compiler inserts -- for alignment, or trailing -- is invisible
/// in the source but real on the wire; this rejects it. A struct of
/// `u8, u8, u16, u32` (size 8) passes; `u8, u32` (size 8, five bytes of data)
/// does not.
pub fn assertNoPadding(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            comptime var sum: usize = 0;
            inline for (s.field_types) |FT| {
                sum += @sizeOf(FT);
            }
            if (@sizeOf(T) != sum)
                @compileError(std.fmt.comptimePrint(
                    "{s}: size is {d}, but its fields sum to {d} (padding)",
                    .{ @typeName(T), @sizeOf(T), sum },
                ));
        },
        else => @compileError(std.fmt.comptimePrint("{s}: not a struct", .{@typeName(T)})),
    }
}

// -- tests (run on the host with `zig build test`) ---------------------------

const testing = @import("std").testing;

/// A packed, extern struct with no padding: every assertion must accept it.
const Good = extern struct {
    a: u8,
    b: u8,
    c: u16,
    d: u32,
};

test "the checks accept a struct that satisfies them" {
    assertSize(Good, 8);
    assertAlignOf(Good, 4);
    assertExternStruct(Good);
    assertOffsetOf(Good, "c", 2);
    assertOffsetOf(Good, "d", 4);
    assertNoPadding(Good);
}

test "assertSize and assertOffsetOf fold away" {
    // Nothing to observe at run time; the value is that they compiled at all
    // above. A wrong argument would have been a compile error.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Good));
}
