// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The whole-disk image the installer copies onto the target's EFI system
// partition (FAT): the Renux loader, /boot/kernel/kernel and a loader.conf that
// names the installed root (vfs.root.mountfrom). Empty in a normal build; an
// installer build hands a real image in as the `espimage` import, and
// kernel/dev/md exposes it as /dev/md1.

/// The embedded ESP image. Empty when the kernel carries none.
pub const bytes: []const u8 = @embedFile("espimage");
