// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Kernel root source file.
//
// This file wires the kernel together: it installs the panic hook and pulls in
// the machine-independent subsystems. Machine-dependent code is reached only
// through sys/arch/arch.zig, which each subsystem imports itself; the root
// never names a port-specific file.

const std: type = @import("std");

/// Route panics to the kernel console.
pub const panic = std.debug.FullPanic(@import("kern/subr_prf.zig").panic);

comptime {
    _ = @import("arch/arch.zig");
    _ = @import("kern/init_main.zig");
    _ = @import("vm/vm_init.zig");
    _ = @import("dev/pckbport/pckbd.zig");
    _ = @import("dev/cons.zig");
    _ = @import("dev/tty.zig");
    _ = @import("dev/mem.zig");
    _ = @import("dev/fb/fb.zig");
    _ = @import("fs/tmpfs/tmpfs_vfsops.zig");
    _ = @import("fs/ext2fs/ext2fs_vfsops.zig");
}
