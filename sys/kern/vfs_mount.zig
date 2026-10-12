// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Filesystem registry and mount bookkeeping.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_init.c and the mount
// list half of vfs_mount.c: filesystems register a Vfs record, and mounting one
// creates a Mount that remembers the filesystem's private data and its root
// vnode. The root filesystem is the one namei() starts from.

const vnode: type = @import("../sys/vnode.zig");
const mount: type = @import("../sys/mount.zig");
const prf: type = @import("subr_prf.zig");

/// Maximum number of simultaneously mounted filesystems.
pub const MAXMOUNT: usize = 8;

/// Head of the list of registered filesystem types.
var vfs_list: ?*mount.Vfs = null;

/// Mounted filesystems, and how many are in use.
var mounts: [MAXMOUNT]mount.Mount = undefined;
var nmounts: usize = 0;

/// The filesystem mounted as the system root.
var rootmount: ?*mount.Mount = null;

/// Register a filesystem type. Called once per filesystem, at SI_SUB_VFS.
pub fn register(vfs: *mount.Vfs) void {
    vfs.next = vfs_list;
    vfs_list = vfs;
}

/// Compare two names for equality.
fn nameEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

/// Find a registered filesystem by name.
pub fn find(name: []const u8) ?*mount.Vfs {
    var p: ?*mount.Vfs = vfs_list;
    while (p) |vfs| : (p = vfs.next) {
        if (nameEqual(vfs.name, name)) {
            return vfs;
        }
    }
    return null;
}

/// Mount the filesystem named `name`, passing `data` to its mount routine.
/// Returns the new Mount, or null on failure.
pub fn mountFs(name: []const u8, data: ?*anyopaque) ?*mount.Mount {
    if (nmounts >= MAXMOUNT) {
        return null;
    }
    const vfs: *mount.Vfs = find(name) orelse return null;

    const mp: *mount.Mount = &mounts[nmounts];
    mp.mnt_op = vfs.ops;
    mp.mnt_data = null;
    mp.mnt_root = null;
    mp.mnt_flag = 0;
    mp.mnt_name = name;

    if (vfs.ops.mount(mp, data) != 0) {
        return null;
    }

    var vp: ?*vnode.Vnode = null;
    if (vfs.ops.root(mp, &vp) != 0) {
        return null;
    }
    const root: *vnode.Vnode = vp orelse return null;
    root.v_flag |= vnode.VROOT;
    mp.mnt_root = root;

    nmounts += 1;
    prf.log(prf.LOG_INFO, "%s: mounted", .{name});
    return mp;
}

/// Record `mp` as the system root filesystem.
pub fn setRoot(mp: *mount.Mount) void {
    rootmount = mp;
}

/// Mount the filesystem `name` on the directory `dir`: the new filesystem's
/// root is reached whenever namei() descends through `dir` (NetBSD's
/// vfs_mountroot()-style rootmount for a directory). Returns the mount, or null.
pub fn mountOn(dir: *vnode.Vnode, name: []const u8, data: ?*anyopaque) ?*mount.Mount {
    if (dir.v_type != .vdir) {
        return null;
    }
    const mp: *mount.Mount = mountFs(name, data) orelse return null;
    dir.v_mountedhere = mp;
    return mp;
}

/// Follow a mount point: if `vp` is a directory a filesystem is mounted on,
/// return that filesystem's root; otherwise return `vp`.
pub fn cross(vp: *vnode.Vnode) *vnode.Vnode {
    var v: *vnode.Vnode = vp;
    var guard: usize = 0;
    while (v.v_mountedhere) |m| {
        const root: ?*vnode.Vnode = m.mnt_root;
        if (root == null or guard >= 8) {
            break;
        }
        v = root.?;
        guard += 1;
    }
    return v;
}

/// The root vnode of the system, or null before root is mounted.
pub fn getRoot() ?*vnode.Vnode {
    const mp: *mount.Mount = rootmount orelse return null;
    return mp.mnt_root;
}
