// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Pathname lookup.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_lookup.c, reduced to
// namei() for LOOKUP only: it walks a path component by component from a
// starting directory, asking each directory's VOP_LOOKUP for the next vnode.
// "." is answered locally; ".." is left to the filesystem, which knows its own
// parent. An absolute path starts at the root, a relative one at the given
// directory. Mount points are crossed and symbolic links are followed.

const vnode: type = @import("../sys/vnode.zig");
const namei: type = @import("../sys/namei.zig");
const param: type = @import("../sys/param.zig");
const vfs_mount: type = @import("vfs_mount.zig");

/// Maximum number of symbolic links followed for one pathname.
const MAXSYMLINKS: u32 = 16;

/// Resolve `path` starting from `start` (or the root, for an absolute path or
/// when `start` is null), or null when any component is missing.
pub fn nameiAt(start: ?*vnode.Vnode, path: []const u8) ?*vnode.Vnode {
    return nameiDepth(start, path, 0, true);
}

/// Like nameiAt(), but a symbolic link in the last component is returned
/// itself instead of being followed (FreeBSD's NOFOLLOW, for readlink(2) and
/// lstat(2)).
pub fn nameiAtNoFollow(start: ?*vnode.Vnode, path: []const u8) ?*vnode.Vnode {
    return nameiDepth(start, path, 0, false);
}

fn nameiDepth(start: ?*vnode.Vnode, path: []const u8, depth: u32, follow_last: bool) ?*vnode.Vnode {
    if (depth > MAXSYMLINKS or path.len >= param.MAXPATHLEN) {
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
        vp = vfs_mount.cross(vfs_mount.getRoot() orelse return null);
        while (i < len and buf[i] == '/') : (i += 1) {}
    } else {
        vp = vfs_mount.cross(start orelse (vfs_mount.getRoot() orelse return null));
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

        // ".." at the root of a mounted filesystem continues in the
        // directory it is mounted on.
        if (namelen == 2 and buf[comp_start] == '.' and buf[comp_start + 1] == '.') {
            vp = vfs_mount.uncover(vp);
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

        const found: *vnode.Vnode = vp.v_op.lookup(vp, &cnp) orelse return null;
        const next: *vnode.Vnode = vfs_mount.cross(found);

        // Follow a symbolic link (in a helper so this frame stays small).
        if (next.v_type == .vlnk and (follow_last or !islast)) {
            return followLink(next, vp, buf[i..len], depth, follow_last);
        }

        vp = next;
    }

    return vp;
}

/// Resolve a symbolic link `next` found in directory `vp`: read its target and
/// continue the lookup, resolving the target from `vp` (a relative target) or
/// from the root (an absolute one), appending `rest` (the path left after the
/// link).
fn followLink(next: *vnode.Vnode, vp: *vnode.Vnode, rest: []const u8, depth: u32, follow_last: bool) ?*vnode.Vnode {
    var lbuf: [param.MAXPATHLEN]u8 = undefined;
    const ln: isize = next.v_op.read(next, 0, &lbuf);
    if (ln <= 0) {
        return null;
    }
    const link: []const u8 = lbuf[0..@intCast(ln)];

    var tmp: [param.MAXPATHLEN]u8 = undefined;
    var tl: usize = 0;
    var k: usize = 0;
    while (k < link.len and tl < tmp.len) : (k += 1) {
        tmp[tl] = link[k];
        tl += 1;
    }
    if (rest.len > 0 and tl < tmp.len) {
        tmp[tl] = '/';
        tl += 1;
        var r: usize = 0;
        while (r < rest.len and tl < tmp.len) : (r += 1) {
            tmp[tl] = rest[r];
            tl += 1;
        }
    }

    const base: ?*vnode.Vnode = if (link.len > 0 and link[0] == '/') null else vp;
    return nameiDepth(base, tmp[0..tl], depth + 1, follow_last);
}

/// Resolve an absolute or root-relative `path` (used before a process exists).
pub fn nameiLookup(path: []const u8) ?*vnode.Vnode {
    return nameiAt(null, path);
}
