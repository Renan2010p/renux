// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Vnode management.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_subr.c, reduced to
// what a first filesystem needs: allocating a vnode and adjusting its
// reference counts. The VOP_* wrappers of NetBSD are not needed here because a
// vnode carries its operation vector directly (v_op), so callers write
// vp.v_op.read(...) instead of VOP_READ(vp, ...).

const vnode: type = @import("../sys/vnode.zig");
const mount: type = @import("../sys/mount.zig");
const kmem: type = @import("subr_kmem.zig");

/// Allocate a fresh vnode of `v_type` backed by `data`, with operations `ops`
/// and belonging to filesystem `mp`. The vnode starts with one reference.
pub fn allocVnode(
    v_type: vnode.Vtype,
    ops: *const vnode.VnodeOps,
    data: ?*anyopaque,
    mp: ?*mount.Mount,
) ?*vnode.Vnode {
    const vp: *vnode.Vnode = kmem.zallocAs(vnode.Vnode) orelse return null;
    vp.v_type = v_type;
    vp.v_flag = 0;
    vp.v_op = ops;
    vp.v_data = data;
    vp.v_mount = mp;
    vp.v_usecount = 1;
    vp.v_holdcnt = 0;
    vp.v_ino = 0;
    return vp;
}

/// Take a new reference to `vp`.
pub fn vref(vp: *vnode.Vnode) void {
    vp.v_usecount += 1;
}

/// Drop a reference to `vp`. When the last reference goes away the filesystem
/// is told the vnode is inactive.
///
/// A vnode is never freed here: filesystems such as tmpfs keep one vnode per
/// node for the lifetime of the mount and hand it out again, so the kernel must
/// not reclaim it out from under them yet.
pub fn vrele(vp: *vnode.Vnode) void {
    if (vp.v_usecount > 0) {
        vp.v_usecount -= 1;
    }
    if (vp.v_usecount == 0) {
        vp.v_op.inactive(vp);
    }
}
