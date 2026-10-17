// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 sysarch.
//
// This is the Zig counterpart of FreeBSD's sys/amd64/amd64/sys_machdep.c,
// reduced to the thread-pointer requests a libc uses to install its TLS:
// sysarch(AMD64_SET_FSBASE/AMD64_GET_FSBASE) reads and writes IA32_FS_BASE,
// and AMD64_SET_TLSBASE/AMD64_GET_TLSBASE do the same (on x86 the TLS base is
// the thread pointer). The FreeBSD ABI numbers are used so FreeBSD binaries
// work unmodified.

const cpufunc: type = @import("../../x86/include/cpufunc.zig");
const sys: type = @import("../../../sys/syscall.zig");
const errno: type = @import("../../../sys/errno.zig");
const kern_proc: type = @import("../../../core/kern_proc.zig");

pub const AMD64_GET_FSBASE: u64 = 128;
pub const AMD64_SET_FSBASE: u64 = 129;
pub const AMD64_GET_GSBASE: u64 = 130;
pub const AMD64_SET_GSBASE: u64 = 131;
pub const AMD64_GET_TLSBASE: u64 = 135;
pub const AMD64_SET_TLSBASE: u64 = 136;

/// sysarch(2): machine-dependent architecture requests.
pub fn sysSysarch(args: [sys.MAXARGS]u64) u64 {
    const op: u64 = args[0];
    const parms: u64 = args[1];
    if (parms == 0) {
        return sys.signed(-errno.EFAULT);
    }

    switch (op) {
        AMD64_SET_FSBASE, AMD64_SET_TLSBASE => {
            const p: *align(1) const u64 = @ptrFromInt(parms);
            const base: u64 = p.*;
            cpufunc.setFsBase(base);
            kern_proc.curthread.fsbase = base;
            return 0;
        },
        AMD64_GET_FSBASE, AMD64_GET_TLSBASE => {
            const p: *align(1) u64 = @ptrFromInt(parms);
            p.* = cpufunc.fsBase();
            return 0;
        },
        else => return sys.signed(-errno.EINVAL),
    }
}
