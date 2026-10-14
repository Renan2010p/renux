// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The root filesystem image embedded in the kernel.
//
// This is the Zig counterpart of FreeBSD's MD_ROOT (sys/dev/md/md.c): instead
// of mounting the root from a device, the kernel carries the image in its own
// text and unpacks it as the root. The build makes the ext2 image
// (tools/mkrootfs.sh) and hands it in as the `rootimage` import (docs: md(4),
// the MD_ROOT option); a kernel built with -Dmdroot=false gets an empty one.

/// The embedded root image. Empty when the kernel carries none.
pub const bytes: []const u8 = @embedFile("rootimage");
