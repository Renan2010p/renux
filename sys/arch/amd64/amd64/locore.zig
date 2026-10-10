// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

const cpu: type = @import("../../x86/include/cpufunc.zig");

extern fn main() void;

export fn _start() callconv(.c) void {
    cpu.startup();

    @call(.never_inline, main, .{});
}
