// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Machine-independent architecture dispatch for the C library.
//
// The Zig counterpart of NetBSD's lib/libc/arch/<arch>/ selection: it picks the
// port's system call primitive at compile time, so the rest of the library never
// names an architecture.

const std: type = @import("std");
const builtin: type = @import("builtin");
const Target: type = std.Target;
const cpu_arch: Target.Cpu.Arch = builtin.target.cpu.arch;

const impl: type = switch (cpu_arch) {
    .x86_64 => @import("amd64/sys/__syscall.zig"),
    else => @compileError("libc: unsupported architecture"),
};

/// The architecture's system call primitive.
pub const syscall: type = impl;
