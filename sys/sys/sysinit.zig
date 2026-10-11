// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// SYSINIT: priority-ordered subsystem initialization.
//
// This is the Zig counterpart of FreeBSD's SYSINIT machinery (sys/sys/kernel.h
// plus the linker set in sys/sys/linker_set.h). A subsystem registers an
// initializer at compile time, tagged with a subsystem identifier (SI_SUB_*) and
// an order within it (SI_ORDER_*); the registration lands in a linker set, and
// mi_startup() sorts and runs them. This is the "init" mechanism FreeBSD uses
// instead of a hand-ordered main().

/// An initializer function. `udata` is the registration's opaque argument, as
/// in FreeBSD's `sysinit_cfunc_t`.
pub const Cfunc: type = *const fn (udata: ?*const anyopaque) callconv(.c) void;

/// A single registration, matching FreeBSD's `struct sysinit` layout (minus the
/// list links, which are not needed because the linker set is already
/// contiguous).
pub const Sysinit: type = extern struct {
    /// Subsystem identifier (SI_SUB_*).
    subsystem: u32,
    /// Order within the subsystem (SI_ORDER_*).
    order: u32,
    /// Function to run.
    func: Cfunc,
    /// Opaque argument passed to `func`.
    udata: ?*const anyopaque,
};

// Subsystem identifiers, as FreeBSD's sys/sys/kernel.h defines them.
pub const SI_SUB_COPYRIGHT: u32 = 0x0800001; // first use of console
pub const SI_SUB_VM: u32 = 0x1000000; // virtual memory system init
pub const SI_SUB_INTR: u32 = 0x2800000; // interrupt threads
pub const SI_SUB_CONFIGURE: u32 = 0x3800000; // configure devices
pub const SI_SUB_VFS: u32 = 0x2000000; // filesystems
pub const SI_SUB_DRIVERS: u32 = 0x3100000; // device drivers
pub const SI_SUB_CLOCKS: u32 = 0x4800000; // real time and stat clocks
pub const SI_SUB_LAST: u32 = 0xfffffff; // final initialization

// Order within a subsystem, as FreeBSD defines them.
pub const SI_ORDER_FIRST: u32 = 0x0000000;
pub const SI_ORDER_SECOND: u32 = 0x0000001;
pub const SI_ORDER_THIRD: u32 = 0x0000002;
pub const SI_ORDER_FOURTH: u32 = 0x0000003;
pub const SI_ORDER_FIFTH: u32 = 0x0000004;
pub const SI_ORDER_MIDDLE: u32 = 0x1000000;

/// Name of the section that holds the linker set.
const section: []const u8 = "set_sysinit_set";

/// Register a subsystem initializer, as FreeBSD's SYSINIT() macro does.
///
/// `name` must be unique; it becomes the symbol of the linker-set entry.
pub fn SYSINIT(
    comptime name: []const u8,
    comptime subsystem: u32,
    comptime order: u32,
    comptime func: Cfunc,
    comptime udata: ?*const anyopaque,
) void {
    const holder = struct {
        var entry: Sysinit align(8) linksection(section) = .{
            .subsystem = subsystem,
            .order = order,
            .func = func,
            .udata = udata,
        };
    };
    @export(&holder.entry, .{ .name = name, .linkage = .strong });
}

// Bounds of the linker set, provided by the linker.
extern var __start_set_sysinit_set: Sysinit;
extern var __stop_set_sysinit_set: Sysinit;

/// The registered initializers, in link order.
pub fn entries() []Sysinit {
    const start: usize = @intFromPtr(&__start_set_sysinit_set);
    const stop: usize = @intFromPtr(&__stop_set_sysinit_set);
    const count: usize = (stop - start) / @sizeOf(Sysinit);
    const base: [*]Sysinit = @ptrFromInt(start);
    return base[0..count];
}

fn precedes(a: Sysinit, b: Sysinit) bool {
    if (a.subsystem != b.subsystem) {
        return a.subsystem < b.subsystem;
    }
    return a.order < b.order;
}

/// Sort the initializers by (subsystem, order), in place.
pub fn sort(list: []Sysinit) void {
    var i: usize = 1;
    while (i < list.len) : (i += 1) {
        const key = list[i];
        var j: usize = i;
        while (j > 0 and precedes(key, list[j - 1])) : (j -= 1) {
            list[j] = list[j - 1];
        }
        list[j] = key;
    }
}
