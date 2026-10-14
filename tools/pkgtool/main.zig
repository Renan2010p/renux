// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// pkgtool: read FreeBSD package repositories on the build host.
//
// FreeBSD's pkg(8) only runs on FreeBSD, but building a Renux image wants a
// few packages from the FreeBSD repository (bash, nano). This tool does the
// two host-side steps tools/get-freebsd-pkg.sh needs, with no dependency
// beyond Zig's standard library:
//
//   pkgtool resolve <packagesite.yaml> <name>...
//       print, for the named packages and everything they depend on
//       (dependencies first), one line: "<repopath> <sha256> <name>-<version>"
//
//   pkgtool extract <file.pkg|packagesite.pkg> <dir>
//       unpack a package (a zstd-compressed tar) into <dir>; the absolute
//       paths packages use (/usr/local/...) land under <dir>, and no path can
//       escape it
//
//   pkgtool sum <file>
//       print the file's checksum the way pkg(8) writes it in the catalog's
//       "sum" field: "2$" (BLAKE2) and BLAKE2b-512 in pkg's base32
//       (libpkg/pkg_checksum.c)
//
// The catalog (packagesite.yaml) holds one JSON object per line. Verifying
// its signature is the script's job (openssl); comparing each downloaded
// package's `pkgtool sum` with the catalog's is too.

const std = @import("std");
const Io = std.Io;

fn usage() noreturn {
    std.process.fatal("usage: pkgtool resolve <packagesite.yaml> <name>... | pkgtool extract <file.pkg> <dir> | pkgtool sum <file>", .{});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) usage();
    if (std.mem.eql(u8, args[1], "sum")) {
        if (args.len != 3) usage();
        try sum(io, args[2]);
    } else if (std.mem.eql(u8, args[1], "extract")) {
        if (args.len != 4) usage();
        try extract(io, args[2], args[3]);
    } else if (std.mem.eql(u8, args[1], "resolve")) {
        try resolve(io, arena, args[2], args[3..]);
    } else usage();
}

/// pkg's base32 alphabet and bit order (pkg_checksum_encode_base32()).
fn base32(in: []const u8, out: []u8) []const u8 {
    const b32 = "ybndrfg8ejkmcpqxot1uwisza345h769";
    var r: usize = 0;
    var remain: i32 = -1;
    for (in, 0..) |byte, i| {
        const v: u32 = byte;
        const rem: u32 = if (remain < 0) 0 else @intCast(remain);
        switch (i % 5) {
            0 => {
                out[r] = b32[v & 0x1f];
                r += 1;
                remain = @intCast(v >> 5);
            },
            1 => {
                const x: u32 = rem | v << 3;
                out[r] = b32[x & 0x1f];
                out[r + 1] = b32[x >> 5 & 0x1f];
                r += 2;
                remain = @intCast(x >> 10);
            },
            2 => {
                const x: u32 = rem | v << 1;
                out[r] = b32[x & 0x1f];
                r += 1;
                remain = @intCast(x >> 5);
            },
            3 => {
                const x: u32 = rem | v << 4;
                out[r] = b32[x & 0x1f];
                out[r + 1] = b32[x >> 5 & 0x1f];
                r += 2;
                remain = @intCast(x >> 10 & 0x3);
            },
            else => {
                const x: u32 = rem | v << 2;
                out[r] = b32[x & 0x1f];
                out[r + 1] = b32[x >> 5 & 0x1f];
                r += 2;
                remain = -1;
            },
        }
    }
    if (remain >= 0) {
        out[r] = b32[@intCast(remain)];
        r += 1;
    }
    return out[0..r];
}

/// Print `path`'s checksum as the catalog's "sum" field holds it.
fn sum(io: Io, path: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var h: std.crypto.hash.blake2.Blake2b512 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        h.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var digest: [64]u8 = undefined;
    h.final(&digest);
    var enc: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    try out.interface.print("2${s}\n", .{base32(&digest, &enc)});
    try out.interface.flush();
}

/// `name` as a path relative to the extraction root: without leading
/// slashes, and null when it is empty or tries to climb out with "..".
fn relPath(name: []const u8) ?[]const u8 {
    const rel = std.mem.trimStart(u8, name, "/");
    if (rel.len == 0) return null;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return null;
    }
    return rel;
}

/// Unpack the zstd-compressed tar `path` into directory `dest`.
fn extract(io: Io, path: []const u8, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    const window: []u8 = try std.heap.page_allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer std.heap.page_allocator.free(window);
    var zstd: std.compress.zstd.Decompress = .init(&file_reader.interface, window, .{});

    try cwd.createDirPath(io, dest);
    var dir = try cwd.openDir(io, dest, .{});
    defer dir.close(io);

    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&zstd.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var contents_buf: [16 * 1024]u8 = undefined;
    while (try it.next()) |entry| {
        const rel = relPath(entry.name) orelse continue;
        switch (entry.kind) {
            .directory => try dir.createDirPath(io, rel),
            .file => {
                if (std.fs.path.dirname(rel)) |d| try dir.createDirPath(io, d);
                const perm: Io.File.Permissions = if ((entry.mode & 0o111) != 0) .executable_file else .default_file;
                const out = try dir.createFile(io, rel, .{ .permissions = perm });
                defer out.close(io);
                var w = out.writer(io, &contents_buf);
                try it.streamRemaining(entry, &w.interface);
                try w.interface.flush();
            },
            .sym_link => {
                if (std.fs.path.dirname(rel)) |d| try dir.createDirPath(io, d);
                dir.deleteFile(io, rel) catch {};
                try dir.symLink(io, entry.link_name, rel, .{});
            },
        }
    }
}

const Pkg = struct {
    name: []const u8,
    version: []const u8,
    repopath: []const u8,
    sum: []const u8,
    deps: []const []const u8,
};

/// The value of `"key":"..."` in one catalog line, without parsing it all.
fn field(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const pat = "\"" ++ key ++ "\":\"";
    const at = std.mem.find(u8, line, pat) orelse return null;
    const start = at + pat.len;
    const end = std.mem.findScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

/// Print the named packages and their dependencies, dependencies first.
fn resolve(io: Io, arena: std.mem.Allocator, catalog_path: []const u8, names: []const [:0]const u8) !void {
    const catalog = try Io.Dir.cwd().readFileAlloc(io, catalog_path, arena, .unlimited);

    // Index the catalog by package name (one JSON object per line).
    var lines: std.StringHashMapUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, catalog, '\n');
    while (it.next()) |line| {
        const name = field(line, "name") orelse continue;
        try lines.put(arena, name, line);
    }

    var done: std.StringHashMapUnmanaged(void) = .empty;
    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    for (names) |n| try visit(arena, &lines, &done, n, &out.interface);
    try out.interface.flush();
}

fn visit(
    arena: std.mem.Allocator,
    lines: *std.StringHashMapUnmanaged([]const u8),
    done: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    out: *Io.Writer,
) !void {
    if (done.contains(name)) return;
    try done.put(arena, name, {});
    const line = lines.get(name) orelse std.process.fatal("pkgtool: no package named {s} in the catalog", .{name});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    const obj = parsed.object;
    if (obj.get("deps")) |deps| {
        var dit = deps.object.iterator();
        while (dit.next()) |e| try visit(arena, lines, done, e.key_ptr.*, out);
    }
    try out.print("{s} {s} {s}-{s}\n", .{
        obj.get("repopath").?.string,
        obj.get("sum").?.string,
        name,
        obj.get("version").?.string,
    });
}
