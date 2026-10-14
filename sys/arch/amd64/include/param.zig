// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 machine parameters.
//
// The Zig counterpart of FreeBSD's sys/amd64/include/param.h
// (<machine/param.h>): the machine names uname(3) and the boot banner report.

/// The machine (hardware platform) name.
pub const MACHINE: []const u8 = "amd64";

/// The machine architecture name (the instruction set).
pub const MACHINE_ARCH: []const u8 = "amd64";
