// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// pmap interface for the x86 family.
//
// This is the Zig counterpart of NetBSD's sys/arch/x86/include/pmap.h: the
// machine-dependent half of the VM system, which owns page tables. The
// implementation lives in sys/arch/x86/x86/pmap.zig.

/// Protection requested for a mapping.
pub const Prot: type = enum {
    /// Kernel read/write data (not executable).
    kernel_rw,
    /// Kernel read-only data (not executable).
    kernel_ro,
    /// Kernel executable code (read/execute).
    kernel_rx,
    /// User read/write data (not executable).
    user_rw,
    /// User read-only data (not executable).
    user_ro,
    /// User executable code (read/execute).
    user_rx,
};
