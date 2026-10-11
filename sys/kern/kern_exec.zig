// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// exec(): load an executable image.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_exec.c: the front end
// that inspects a program image and dispatches to the right loader. Only the
// ELF image activator exists so far.

const exec_elf: type = @import("exec_elf.zig");
const arch: type = @import("../arch/arch.zig");

/// Result of a successful exec.
pub const Result: type = struct {
    /// Entry point virtual address.
    entry: u64,
};

/// Load `bytes` as a program image into page map `pmap`, or return null if no
/// activator matches.
pub fn exec(pmap: arch.pmap.Pmap, bytes: []const u8) ?Result {
    if (!exec_elf.isElf(bytes)) {
        return null;
    }
    const loaded = exec_elf.load(pmap, bytes) orelse return null;
    return .{ .entry = loaded.entry };
}
