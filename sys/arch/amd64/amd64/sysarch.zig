// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// amd64 sysarch.
//
// This is the Zig counterpart of NetBSD's sys/arch/amd64/amd64/sysarch.c,
// reduced to the thread-pointer operations a libc uses to install its TLS:
// sysarch(AMD64_SET_FSBASE/AMD64_GET_FSBASE) reads and writes IA32_FS_BASE.

const cpufunc: type = @import("../../x86/include/cpufunc.zig");
const sys: type = @import("../../../sys/syscall.zig");
const errno: type = @import("../../../sys/errno.zig");

pub const AMD64_SET_FSBASE: u64 = 128;
pub const AMD64_GET_FSBASE: u64 = 129;

/// sysarch(2): machine-dependent architecture requests.
pub fn sysSysarch(args: [sys.MAXARGS]u64) u64 {
    const op: u64 = args[0];
    const parms: u64 = args[1];
    if (parms == 0) {
        return sys.signed(-errno.EFAULT);
    }

    switch (op) {
        AMD64_SET_FSBASE => {
            const p: *const u64 = @ptrFromInt(parms);
            cpufunc.setFsBase(p.*);
            return 0;
        },
        AMD64_GET_FSBASE => {
            const p: *u64 = @ptrFromInt(parms);
            p.* = cpufunc.fsBase();
            return 0;
        },
        else => return sys.signed(-errno.EINVAL),
    }
}
