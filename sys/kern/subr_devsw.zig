// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Device switch dispatch.
//
// This is the Zig counterpart of NetBSD's sys/kern/subr_devsw.c, reduced to
// opening a character device: the major number in the node's rdev selects a
// cdevsw entry, its open routine supplies a per-open context, and the returned
// open file carries a small FileOps vector that forwards reads and writes to
// the device. A device-backed descriptor therefore looks like any other open
// file to the rest of the kernel.

const conf: type = @import("../sys/conf.zig");
const file: type = @import("../sys/file.zig");
const stat: type = @import("../sys/stat.zig");
const kmem: type = @import("subr_kmem.zig");

/// Per-open state of a device-backed descriptor.
const DevFile: type = struct {
    cdev: *const conf.Cdevsw,
    ctx: ?*anyopaque,
    dev: u64,
};

/// The FileOps shared by every device-backed descriptor.
const dev_ops: file.FileOps = .{
    .read = devRead,
    .write = devWrite,
    .ioctl = devIoctl,
    .mmap = devMmap,
    .stat = devStat,
    .close = devClose,
    .poll = devPoll,
};

fn devPoll(f: *file.File) u16 {
    const df: *DevFile = cast(f);
    const hook = df.cdev.poll orelse return file.POLLIN | file.POLLOUT;
    return hook(df.ctx);
}

fn cast(f: *file.File) *DevFile {
    const raw: ?*anyopaque = f.f_data;
    return @ptrCast(@alignCast(raw.?));
}

fn devRead(f: *file.File, buf: []u8) isize {
    const df: *DevFile = cast(f);
    return df.cdev.read(df.ctx, buf);
}

fn devWrite(f: *file.File, buf: []const u8) isize {
    const df: *DevFile = cast(f);
    return df.cdev.write(df.ctx, buf);
}

fn devIoctl(f: *file.File, cmd: u64, arg: u64) i32 {
    const df: *DevFile = cast(f);
    return df.cdev.ioctl(df.ctx, cmd, arg);
}

fn devMmap(f: *file.File, offset: u64, prot: u32) ?u64 {
    const df: *DevFile = cast(f);
    const hook = df.cdev.mmap orelse return null;
    return hook(df.ctx, offset, prot);
}

fn devStat(f: *file.File, st: *stat.Stat) i32 {
    const df: *DevFile = cast(f);
    st.dev = df.dev;
    st.ino = 0;
    st.nlink = 1;
    st.mode = @truncate(stat.S_IFCHR | 0o620);
    st.padding0 = 0;
    st.uid = 0;
    st.gid = 0;
    st.padding1 = 0;
    st.rdev = df.dev;
    st.atim = .{ .sec = 0, .nsec = 0 };
    st.mtim = .{ .sec = 0, .nsec = 0 };
    st.ctim = .{ .sec = 0, .nsec = 0 };
    st.size = 0;
    st.blocks = 0;
    st.blksize = 4096;
    st.flags = 0;
    st.gen = 0;
    st.spare = @splat(0);
    st.birthtim = .{ .sec = 0, .nsec = 0 };
    return 0;
}

fn devClose(f: *file.File) i32 {
    const df: *DevFile = cast(f);
    const err: i32 = df.cdev.close(df.ctx);
    kmem.free(@ptrCast(df));
    return err;
}

/// Open the character device numbered `dev`; returns a new open file, or null
/// when no driver is registered for its major number.
pub fn cdevOpen(dev: u64, flags: i32) ?*file.File {
    const maj: usize = conf.major(dev);
    const sw: *const conf.Cdevsw = conf.cdevsw[maj] orelse return null;

    const ctx: ?*anyopaque = sw.open(dev, flags);
    const df: *DevFile = kmem.zallocAs(DevFile) orelse return null;
    df.cdev = sw;
    df.ctx = ctx;
    df.dev = dev;

    const f: *file.File = kmem.zallocAs(file.File) orelse {
        kmem.free(@ptrCast(df));
        return null;
    };
    var mode: i32 = 0;
    if ((flags & 3) != 1) {
        mode |= file.FREAD;
    }
    if ((flags & 3) != 0) {
        mode |= file.FWRITE;
    }
    f.f_type = file.DTYPE_VNODE;
    f.f_flag = mode;
    f.f_offset = 0;
    f.f_count = 1;
    f.f_data = df;
    f.f_ops = &dev_ops;
    return f;
}
