// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Process credentials.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_prot.c: real, effective and
// saved user and group ids, supplementary groups, the login name, sessions and
// process groups. The rules are POSIX's, as FreeBSD applies them: a process
// with effective uid 0 may set any id; any other process may only switch
// between its real and saved ids.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const proc: type = @import("../sys/proc.zig");
const kern_proc: type = @import("kern_proc.zig");
const subr_syscall: type = @import("subr_syscall.zig");

fn cur() *proc.Proc {
    return kern_proc.current;
}

fn privileged() bool {
    return cur().euid == 0;
}

fn eperm() u64 {
    return sys.signed(-errno.EPERM);
}

/// An id argument (uid_t/gid_t are 32 bits).
fn id(arg: u64) u32 {
    return @truncate(arg);
}

// -- user ids ------------------------------------------------------------------

pub fn sysGetuid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return cur().uid;
}

pub fn sysGeteuid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return cur().euid;
}

/// setuid(2): root sets all three ids; others may set the effective id to
/// the real or saved one.
pub fn sysSetuid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const u: u32 = id(args[0]);
    if (privileged()) {
        p.uid = u;
        p.euid = u;
        p.svuid = u;
    } else if (u == p.uid or u == p.svuid) {
        p.euid = u;
    } else {
        return eperm();
    }
    return 0;
}

/// seteuid(2).
pub fn sysSeteuid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const u: u32 = id(args[0]);
    if (!privileged() and u != p.uid and u != p.svuid) return eperm();
    p.euid = u;
    return 0;
}

/// setreuid(2): -1 leaves an id unchanged.
pub fn sysSetreuid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const r: u32 = id(args[0]);
    const e: u32 = id(args[1]);
    const keep: u32 = 0xffffffff;
    if (!privileged()) {
        if (r != keep and r != p.uid and r != p.euid) return eperm();
        if (e != keep and e != p.uid and e != p.euid and e != p.svuid) return eperm();
    }
    if (r != keep) p.uid = r;
    if (e != keep) p.euid = e;
    if (r != keep or (e != keep and e != p.uid)) p.svuid = p.euid;
    return 0;
}

/// getresuid(2).
pub fn sysGetresuid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    putId(args[0], p.uid);
    putId(args[1], p.euid);
    putId(args[2], p.svuid);
    return 0;
}

// -- group ids -----------------------------------------------------------------

pub fn sysGetgid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return cur().gid;
}

pub fn sysGetegid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return cur().egid;
}

/// setgid(2), with the same rules as setuid(2).
pub fn sysSetgid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const g: u32 = id(args[0]);
    if (privileged()) {
        p.gid = g;
        p.egid = g;
        p.svgid = g;
    } else if (g == p.gid or g == p.svgid) {
        p.egid = g;
    } else {
        return eperm();
    }
    return 0;
}

/// setegid(2).
pub fn sysSetegid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const g: u32 = id(args[0]);
    if (!privileged() and g != p.gid and g != p.svgid) return eperm();
    p.egid = g;
    return 0;
}

/// setregid(2): -1 leaves an id unchanged.
pub fn sysSetregid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const r: u32 = id(args[0]);
    const e: u32 = id(args[1]);
    const keep: u32 = 0xffffffff;
    if (!privileged()) {
        if (r != keep and r != p.gid and r != p.egid) return eperm();
        if (e != keep and e != p.gid and e != p.egid and e != p.svgid) return eperm();
    }
    if (r != keep) p.gid = r;
    if (e != keep) p.egid = e;
    if (r != keep or (e != keep and e != p.gid)) p.svgid = p.egid;
    return 0;
}

/// getresgid(2).
pub fn sysGetresgid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    putId(args[0], p.gid);
    putId(args[1], p.egid);
    putId(args[2], p.svgid);
    return 0;
}

fn putId(addr: u64, v: u32) void {
    if (addr == 0) return;
    const dst: *align(1) u32 = @ptrFromInt(addr);
    dst.* = v;
}

/// getgroups(2): with a size of 0, the number of groups; otherwise copy them.
pub fn sysGetgroups(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const n: u64 = args[0];
    if (n == 0) return p.ngroups;
    if (n < p.ngroups) return sys.signed(-errno.EINVAL);
    const dst: [*]align(1) u32 = @ptrFromInt(args[1]);
    for (p.groups[0..p.ngroups], 0..) |g, i| dst[i] = g;
    return p.ngroups;
}

/// setgroups(2): root only. FreeBSD keeps the effective gid in groups[0]
/// apart from the list since 14.0; Renux stores the list as given.
pub fn sysSetgroups(args: [sys.MAXARGS]u64) u64 {
    if (!privileged()) return eperm();
    const n: u64 = args[0];
    if (n > proc.NGROUPS) return sys.signed(-errno.EINVAL);
    const p = cur();
    const src: [*]align(1) const u32 = @ptrFromInt(args[1]);
    var i: usize = 0;
    while (i < n) : (i += 1) p.groups[i] = src[i];
    p.ngroups = @intCast(n);
    return 0;
}

/// issetugid(2): whether the process changed ids since its last exec, which
/// makes libc distrust the environment. Renux does not support set-id
/// programs, so never.
pub fn sysIssetugid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return 0;
}

// -- login name ----------------------------------------------------------------

/// getlogin(2): `getlogin(buf, len)`, the session's login name.
pub fn sysGetlogin(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    var n: usize = 0;
    while (n < p.login.len and p.login[n] != 0) n += 1;
    if (args[1] < n + 1) return sys.signed(-errno.ERANGE);
    const dst: [*]u8 = @ptrFromInt(args[0]);
    @memcpy(dst[0..n], p.login[0..n]);
    dst[n] = 0;
    return 0;
}

/// setlogin(2): root only.
pub fn sysSetlogin(args: [sys.MAXARGS]u64) u64 {
    if (!privileged()) return eperm();
    const name: []const u8 = subr_syscall.userStr(args[0]) orelse return sys.signed(-errno.EFAULT);
    if (name.len >= proc.MAXLOGNAME) return sys.signed(-errno.EINVAL);
    const p = cur();
    @memset(&p.login, 0);
    @memcpy(p.login[0..name.len], name);
    return 0;
}

// -- sessions and process groups -------------------------------------------------

/// setsid(2): start a new session, and a new process group in it, both led
/// by the caller. The new session has no controlling terminal. A process
/// group leader may not do it (its group would straddle two sessions).
pub fn sysSetsid(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    const p = cur();
    for (&kern_proc.table) |*q| {
        if (q.state != .unused and q.pgid == p.pid) return eperm();
    }
    p.sid = p.pid;
    p.pgid = p.pid;
    return @intCast(p.pid);
}

/// getpgrp(2): the caller's process group.
pub fn sysGetpgrp(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    return @intCast(cur().pgid);
}

/// The process named by a pid argument: 0 is the caller.
fn target(arg: u64) ?*proc.Proc {
    const pid: i32 = @bitCast(@as(u32, @truncate(arg)));
    if (pid == 0) return cur();
    return kern_proc.pfind(pid);
}

/// getpgid(2): the process group of `pid`.
pub fn sysGetpgid(args: [sys.MAXARGS]u64) u64 {
    const q = target(args[0]) orelse return sys.signed(-errno.ESRCH);
    return @intCast(q.pgid);
}

/// getsid(2): the session of `pid`.
pub fn sysGetsid(args: [sys.MAXARGS]u64) u64 {
    const q = target(args[0]) orelse return sys.signed(-errno.ESRCH);
    return @intCast(q.sid);
}

/// setpgid(2): move the caller or one of its children into process group
/// `pgid` (0: the target's own pid), which must be a new group led by the
/// target or an existing group of the caller's session.
pub fn sysSetpgid(args: [sys.MAXARGS]u64) u64 {
    const p = cur();
    const q = target(args[0]) orelse return sys.signed(-errno.ESRCH);
    if (q != p and q.parent != p) return sys.signed(-errno.ESRCH);
    const req: i32 = @bitCast(@as(u32, @truncate(args[1])));
    if (req < 0) return sys.signed(-errno.EINVAL);
    if (q.sid != p.sid) return eperm();
    if (q.sid == q.pid) return eperm(); // a session leader stays put
    const pgid: i32 = if (req == 0) q.pid else req;
    if (pgid != q.pid) {
        var found: bool = false;
        for (&kern_proc.table) |*r| {
            if (r.state != .unused and r.state != .zombie and r.pgid == pgid and r.sid == p.sid) {
                found = true;
                break;
            }
        }
        if (!found) return eperm();
    }
    q.pgid = pgid;
    return 0;
}
