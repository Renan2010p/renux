// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Pathname lookup.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_lookup.c, reduced to
// namei() for LOOKUP only: it walks a path component by component from the
// filesystem root, asking each directory's VOP_LOOKUP for the next vnode. "."
// is answered locally; ".." is left to the filesystem, which knows its own
// parent. There is no name cache, no symbolic links and no mount crossing yet,
// and a relative path is resolved from the root (a working directory is not
// modelled).

const vnode: type = @import("../sys/vnode.zig");
const namei: type = @import("../sys/namei.zig");
const param: type = @import("../sys/param.zig");
const vfs_mount: type = @import("vfs_mount.zig");

/// Resolve `path` to a vnode, or null when any component is missing.
pub fn nameiLookup(path: []const u8) ?*vnode.Vnode {
    const root: *vnode.Vnode = vfs_mount.getRoot() orelse return null;

    if (path.len >= param.MAXPATHLEN) {
        return null;
    }

    // Work on a private copy so the component names can be sliced out.
    var buf: [param.MAXPATHLEN]u8 = undefined;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        buf[i] = path[i];
    }
    const len: usize = path.len;

    var vp: *vnode.Vnode = root;
    i = 0;
    while (i < len and buf[i] == '/') : (i += 1) {}

    while (i < len) {
        const start: usize = i;
        while (i < len and buf[i] != '/') : (i += 1) {}
        const namelen: usize = i - start;
        while (i < len and buf[i] == '/') : (i += 1) {}
        const islast: bool = (i >= len);

        // "." keeps the current vnode.
        if (namelen == 1 and buf[start] == '.') {
            if (islast) {
                return vp;
            }
            continue;
        }

        var cnp: namei.Componentname = .{
            .nameptr = @as([*]const u8, @ptrCast(&buf[start])),
            .namelen = namelen,
            .nameiop = namei.LOOKUP,
            .flags = namei.FOLLOW,
        };
        if (islast) {
            cnp.flags |= namei.ISLASTCN;
        }

        const next: *vnode.Vnode = vp.v_op.lookup(vp, &cnp) orelse return null;
        vp = next;
    }

    return vp;
}
