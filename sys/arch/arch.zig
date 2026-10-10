// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-independent architecture dispatch.
//
// Machine-independent kernel code must never import an arch-specific module
// directly. Instead it imports this file and reaches the current port through
// the names exported below (cpu, locore, bus_space, consinit, boot). The switch
// on the target CPU architecture selects the MD manifest at compile time.

const std: type = @import("std");
const builtin: type = @import("builtin");
const Target: type = std.Target;
const cpu_arch: Target.Cpu.Arch = builtin.target.cpu.arch;

const machdep_impl: type = switch (cpu_arch) {
    .x86_64 => @import("amd64/conf/files.zig"),
    else => @compileError("arch: unsupported architecture"),
};

/// Low-level CPU primitives (halt, interrupt flags, ...).
pub const cpu: type = machdep_impl.cpu;

/// Low-level entry point.
pub const locore: type = machdep_impl.locore;

/// Bus space access implementation (backing sys/sys/bus.zig).
pub const bus_space: type = machdep_impl.bus_space;

/// Machine-dependent console initialisation (see kern/init_main.zig).
pub const consinit: type = machdep_impl.consinit;

/// Machine-dependent page map (see sys/uvm).
pub const pmap: type = machdep_impl.pmap;

/// Machine-dependent virtual memory parameters.
pub const vmparam: type = machdep_impl.vmparam;

/// Boot protocol bindings provided by the port.
pub const boot: type = machdep_impl.boot;

comptime {
    _ = machdep_impl.locore;
}
