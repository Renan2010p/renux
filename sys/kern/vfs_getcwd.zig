// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// getcwd.
//
// This is the Zig counterpart of NetBSD's sys/kern/vfs_getcwd.c. NetBSD walks
// the vnode tree back to the mount root; ZenBSD keeps the working directory's
// path in the process (updated by chdir), so this simply copies it out.

const sys: type = @import("../sys/syscall.zig");
const proc: type = @import("../sys/proc.zig");
const kern_proc: type = @import("kern_proc.zig");

/// getcwd(2): copy the NUL-terminated working directory path to the caller.
pub fn sysGetcwd(args: [sys.MAXARGS]u64) u64 {
    const buf: u64 = args[0];
    const len: u64 = args[1];
    if (buf == 0 or len == 0) {
        return sys.ERROR;
    }

    const p: *proc.Proc = kern_proc.current;
    const dst: [*]u8 = @ptrFromInt(buf);

    // Copy up to len-1 bytes and NUL-terminate.
    var i: usize = 0;
    while (i < p.cwd_len and i + 1 < len) : (i += 1) {
        dst[i] = p.cwd_path[i];
    }
    dst[i] = 0;
    return 0;
}
