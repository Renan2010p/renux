// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Pathname lookup.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_lookup.c, reduced to
// namei() for LOOKUP only: it walks a path component by component from a
// starting directory, asking each directory's VOP_LOOKUP for the next vnode.
// "." is answered locally; ".." is left to the filesystem, which knows its own
// parent. An absolute path starts at the root, a relative one at the given
// directory. There is no name cache, no symbolic links and no mount crossing
// yet.

const vnode: type = @import("../sys/vnode.zig");
const namei: type = @import("../sys/namei.zig");
const param: type = @import("../sys/param.zig");
const vfs_mount: type = @import("vfs_mount.zig");

/// Resolve `path` starting from `start` (or the root, for an absolute path or
/// when `start` is null), or null when any component is missing.
pub fn nameiAt(start: ?*vnode.Vnode, path: []const u8) ?*vnode.Vnode {
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

    var vp: *vnode.Vnode = undefined;
    i = 0;
    if (len > 0 and buf[0] == '/') {
        vp = vfs_mount.getRoot() orelse return null;
        while (i < len and buf[i] == '/') : (i += 1) {}
    } else {
        vp = start orelse (vfs_mount.getRoot() orelse return null);
    }

    while (i < len) {
        const comp_start: usize = i;
        while (i < len and buf[i] != '/') : (i += 1) {}
        const namelen: usize = i - comp_start;
        while (i < len and buf[i] == '/') : (i += 1) {}
        const islast: bool = (i >= len);

        // "." keeps the current vnode.
        if (namelen == 1 and buf[comp_start] == '.') {
            if (islast) {
                return vp;
            }
            continue;
        }

        var cnp: namei.Componentname = .{
            .nameptr = @as([*]const u8, @ptrCast(&buf[comp_start])),
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

/// Resolve an absolute or root-relative `path` (used before a process exists).
pub fn nameiLookup(path: []const u8) ?*vnode.Vnode {
    return nameiAt(null, path);
}
