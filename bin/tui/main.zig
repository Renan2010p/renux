// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// C program module root (see bin/hello/main.zig).

comptime {
    _ = @import("csu").crt0;
    _ = @import("libc").c;
}
