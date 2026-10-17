// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The root of the installed system, which the installer writes onto the
// target's root partition: the live root plus the system compiler (Zig, as
// /sbin/zig and /lib/zig) and free space to build in. It is a gzip-compressed
// ext2 image (tools/mkrootfs.zig --installed), padded to whole sectors; the
// installer inflates it as it writes. Empty in a normal build; an installer
// build hands it in as the `sysimage` import, and kernel/dev/md exposes it
// as /dev/md2.

/// The embedded, compressed installed-root image. Empty when the kernel
/// carries none.
pub const bytes: []const u8 = @embedFile("sysimage");
