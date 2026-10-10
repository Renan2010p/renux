// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

const arch: type = @import("../arch/arch.zig");

pub export fn main() void {
    arch.cpu.idle();
}
