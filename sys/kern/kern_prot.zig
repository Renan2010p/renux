// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Process credentials.
//
// This is the Zig counterpart of NetBSD's sys/kern/kern_prot.c, reduced to
// getuid(2) and setuid(2). There is no user database yet, so setuid is
// unprivileged and simply records the requested id.

const sys: type = @import("../sys/syscall.zig");
const kern_proc: type = @import("kern_proc.zig");

/// getuid(2): the real user id.
pub fn sysGetuid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.uid);
}

/// setuid(2): set the (single) user id.
pub fn sysSetuid(args: [sys.MAXARGS]u64) u64 {
    kern_proc.current.uid = @truncate(args[0]);
    return 0;
}

/// geteuid(2): the effective user id (the same as the real id here).
pub fn sysGeteuid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.uid);
}

/// getegid(2): the effective group id.
pub fn sysGetegid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

/// setsid(2): start a new session whose id is the calling process. Renux does
/// not model sessions yet, so this just reports success.
pub fn sysSetsid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.pid);
}

/// setlogin(2): set the login name. Not modelled; report success.
pub fn sysSetlogin(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

/// getpgrp(2): the process group. Here every process is its own group.
pub fn sysGetpgrp(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(kern_proc.current.pid);
}

/// setpgid(2): join a process group. Not modelled; report success.
pub fn sysSetpgid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

/// issetugid(2): whether the process is setuid/gid. Never, so far.
pub fn sysIssetugid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}
