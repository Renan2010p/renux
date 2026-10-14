// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The root filesystem image embedded in the kernel.
//
// This is the Zig counterpart of FreeBSD's MD_ROOT (sys/dev/md/md.c): instead
// of mounting the root from a device, the kernel carries the image in its own
// text and unpacks it as the root. The build places the ext2 image at
// kernel/root.img (docs: md(4), the MD_ROOT option); when no userland was staged
// the file is empty and the kernel falls back to the boot modules.

/// The embedded root image. Empty when the image was not built.
pub const bytes: []const u8 = @embedFile("../root.img");
