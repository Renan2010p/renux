// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// mkdisk -- create the persistent disk Renux mounts on /home.
//
// Usage: mkdisk <image>
//
// The image is a sparse 1 GiB file holding an ext2 file system, attached to
// QEMU by `zig build run` as a virtio disk (/dev/vda in Renux). It is created
// only when it does not exist yet: once made it holds the user's files, so no
// build ever touches it again. The file system is written by tools/mkfs.zig;
// on the host, e2fsck(8) checks it and debugfs(8) looks inside.

const std: type = @import("std");
const Io: type = std.Io;
const mkfs: type = @import("mkfs");

/// The disk: 1 GiB of 4 KiB blocks, 1% reserved for root (as on a FreeBSD
/// UFS /home), labelled for /etc/fstab.
const DISK: mkfs.Options = .{
    .bs = 4096,
    .blocks = 262144,
    .reserved_pct = 1,
    .label = "renux-home",
};

pub fn main(init: std.process.Init) !void {
    const io: Io = init.io;
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) std.process.fatal("usage: mkdisk <image>", .{});
    const image: []const u8 = args[1];

    if (Io.Dir.cwd().statFile(io, image, .{})) |_| {
        return; // the disk exists: it holds the user's files
    } else |_| {}

    var options: mkfs.Options = DISK;
    options.image = image;
    try mkfs.makeFs(io, std.heap.page_allocator, options);
    std.debug.print("mkdisk: {s} (1G, ext2) created\n", .{image});
}
