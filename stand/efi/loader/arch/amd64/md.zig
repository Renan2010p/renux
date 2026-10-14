// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The amd64 part of the EFI loader (FreeBSD's stand/efi/loader/arch/amd64),
// imported by the machine-independent loader as the "loader_md" module.

pub const elf64: type = @import("elf64_renux.zig");
pub const tramp: type = @import("amd64_tramp.zig");
