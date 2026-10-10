// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

const std: type = @import("std");
const builtin: type = @import("builtin");
const Target: type = std.Target;
const cpu_arch: Target.Cpu.Arch = builtin.target.cpu.arch;

const machdep_impl: type = switch (cpu_arch) {
    .x86_64 => @import("amd64/machdep.zig"),
    else => @compileError("arch: unsupported architecture"),
};

pub const cpu: type = machdep_impl.cpu;
pub const locore: type = machdep_impl.locore;

comptime {
    _ = machdep_impl.locore;
}
