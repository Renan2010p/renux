// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

const cpu: type = @import("../../x86/include/cpufunc.zig");
const gdt: type = @import("gdt.zig");
const vector: type = @import("vector.zig");

extern fn main() void;

export fn _start() callconv(.c) void {
    cpu.startup();
    gdt.init();
    vector.install();

    @call(.never_inline, main, .{});
}
