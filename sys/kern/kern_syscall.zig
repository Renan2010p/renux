// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// System call dispatch.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_syscall.c: it validates
// a system call number and calls the matching handler from the table. The
// machine-dependent entry (x86/x86/syscall.zig) fills in the arguments.

const syscalls: type = @import("syscalls.zig");
const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const prf: type = @import("subr_prf.zig");
const kern_proc: type = @import("kern_proc.zig");

/// A call with no handler (FreeBSD's nosys). Under bootverbose it is logged
/// as FreeBSD's kern.lognosys does, which lists exactly what a FreeBSD
/// program needs that Renux does not provide yet.
fn nosys(number: u64) u64 {
    if (prf.bootverbose) {
        const p = kern_proc.current;
        prf.printf("pid %d comm %s: nosys %u\n", .{ p.pid, p.name[0..p.name_len], number });
    }
    return sys.signed(-errno.ENOSYS);
}

/// Command name whose system calls are traced (the `truss=<comm>` kernel
/// argument), or empty. A kernel-side counterpart of FreeBSD's truss(1) for
/// bringing up programs before ktrace exists.
var truss_buf: [20]u8 = undefined;
var truss_len: usize = 0;

/// Trace every system call made by processes named `comm`.
pub fn setTruss(comm: []const u8) void {
    truss_len = @min(comm.len, truss_buf.len);
    @memcpy(truss_buf[0..truss_len], comm[0..truss_len]);
}

fn traced() bool {
    if (truss_len == 0) return false;
    const p = kern_proc.current;
    const name: []const u8 = p.name[0..p.name_len];
    if (name.len != truss_len) return false;
    for (name, truss_buf[0..truss_len]) |a, b| if (a != b) return false;
    return true;
}

/// Dispatch `number` with `args`, returning the value to place in the result
/// register. Unimplemented calls return ENOSYS (like FreeBSD's nosys), so a
/// program built for FreeBSD can tell "not supported" from a real error.
pub fn syscall(number: u64, args: [sys.MAXARGS]u64) u64 {
    const r: u64 = dispatch(number, args);
    if (traced()) {
        const p = kern_proc.current;
        prf.printf("%s[%d]: sys %u(%x, %x, %x, %x) = %d\n", .{
            p.name[0..p.name_len], p.pid, number, args[0], args[1], args[2], args[3], @as(i64, @bitCast(r)),
        });
    }
    return r;
}

fn dispatch(number: u64, args: [sys.MAXARGS]u64) u64 {
    if (number >= syscalls.table.len) {
        return nosys(number);
    }
    const handler = syscalls.table[number] orelse return nosys(number);
    return handler(args);
}
