// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// Environment access.
//
// The Zig counterpart of NetBSD's lib/libc/stdlib/getenv.c. The environment
// vector the kernel passes to _start is stored in `environ`; getenv() scans it.

var empty_env: [1]?[*:0]const u8 = .{null};

/// The environment vector (`char **environ`).
pub export var environ: [*]?[*:0]const u8 = @ptrCast(&empty_env);

/// Record the vector _start received.
pub fn setEnviron(envp: [*]?[*:0]const u8) void {
    environ = envp;
}

/// Look up `name` in the environment, or null.
pub fn getenvRaw(name: [*:0]const u8) ?[*:0]u8 {
    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        var k: usize = 0;
        while (name[k] != 0 and entry[k] != 0 and name[k] == entry[k]) : (k += 1) {}
        if (name[k] == 0 and entry[k] == '=') {
            return @ptrCast(@constCast(entry + k + 1));
        }
    }
    return null;
}
