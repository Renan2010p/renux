// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Kernel root source file.
//
// This file wires the kernel together: it installs the panic hook and pulls in
// the machine-independent subsystems. Machine-dependent code is reached only
// through kernel/arch/arch.zig, which each subsystem imports itself; the root
// never names a port-specific file.

const std: type = @import("std");
const debug: type = std.debug;

/// Route panics to the kernel console.
pub const panic: type = debug.FullPanic(@import("core/subr_prf.zig").panic);

comptime {
    _ = @import("arch/arch.zig");
    _ = @import("core/init_main.zig");
    _ = @import("vm/vm_init.zig");
    _ = @import("dev/pckbport/pckbd.zig");
    _ = @import("dev/cons.zig");
    _ = @import("dev/tty.zig");
    _ = @import("dev/mem.zig");
    _ = @import("dev/fb/fb.zig");
    _ = @import("dev/pci/pci.zig");
    _ = @import("dev/virtio/pci/virtio_pci_legacy.zig");
    _ = @import("dev/ata/ata.zig");
    _ = @import("dev/md/md.zig");
    _ = @import("geom/geom_disk.zig");
    _ = @import("geom/geom_part.zig");
    _ = @import("fs/tmpfs/tmpfs_vfsops.zig");
    _ = @import("fs/ext2fs/ext2fs_vfsops.zig");
}
