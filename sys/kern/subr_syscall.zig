// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// System call argument helpers.
//
// NetBSD's generated syscalls.c extracts each handler's typed arguments from
// the register array before calling it. Renux's handlers are hand-written and
// take the raw array, so the small helpers they share (reading a user string,
// the size of an open file) live here.

const sys: type = @import("../sys/syscall.zig");
const param: type = @import("../sys/param.zig");
const file: type = @import("../sys/file.zig");
const vnode: type = @import("../sys/vnode.zig");

/// Read a NUL-terminated string from the calling process's address space.
pub fn userStr(ptr: u64) ?[]const u8 {
    if (ptr == 0) {
        return null;
    }
    const p: [*]const u8 = @ptrFromInt(ptr);
    var len: usize = 0;
    while (len < param.MAXPATHLEN) : (len += 1) {
        if (p[len] == 0) {
            return p[0..len];
        }
    }
    return null;
}

/// Size in bytes of the file behind `f`, or 0 when unknown.
pub fn fileSize(f: *file.File) u64 {
    if (f.f_type != file.DTYPE_VNODE) {
        return 0;
    }
    const raw: ?*anyopaque = f.f_data orelse return 0;
    const vp: *vnode.Vnode = @ptrCast(@alignCast(raw));
    var vap: vnode.Vattr = .{
        .type = .vnone,
        .mode = 0,
        .nlink = 0,
        .size = 0,
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    if (vp.v_op.getattr(vp, &vap) != 0) {
        return 0;
    }
    return vap.size;
}
