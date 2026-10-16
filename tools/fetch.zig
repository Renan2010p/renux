// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// fetch -- download the FreeBSD userland Renux runs on, with Zig alone.
//
// No curl, tar, xz, sha256sum or openssl: everything is done with the
// standard library (std.http.Client for HTTPS and TLS,
// std.compress.xz and std.compress.zstd with std.tar for the archives,
// std.crypto for the checksums and the RSA signature).
//
//   fetch base          the FreeBSD base system (login, sh, the utilities)
//                       -> tools/freebsd/root, checked against a pinned SHA-256
//   fetch pkgs [name..] FreeBSD packages (default: bash nano)
//                       -> tools/freebsd/pkgroot, with pkg's chain of trust:
//                       the catalog's signing key must match a fingerprint
//                       FreeBSD trusts, its RSA signature over the catalog must
//                       verify, and each package's checksum must match.
//   fetch               both (the default)
//
// Nothing it writes is committed; tools/mkrootfs.zig reads the two trees.
// FreeBSD is BSD-licensed; its notices travel with the files.

const std: type = @import("std");
const Io: type = std.Io;
const Allocator: type = std.mem.Allocator;

const RELEASE = "14.5-RELEASE";
const BASE_SHA256 = "d16b68fe0e9e136ce67ab1084042c848bbffecd1eb295f206bd1c6785deb45a4";
const BASE_URL = "https://download.freebsd.org/releases/amd64/" ++ RELEASE ++ "/base.txz";
/// Bump when the unpacked tree changes, so an old tree is redone (3: hard
/// links keep their target's permissions).
const LAYOUT = "3";

const ABI = "FreeBSD:14:amd64";
const REPO = "https://pkg.freebsd.org/" ++ ABI ++ "/quarterly";

const BASE_DIR = "tools/freebsd";
const ROOT = BASE_DIR ++ "/root";
const PKG_DIR = BASE_DIR ++ "/pkg";
const PKGROOT = BASE_DIR ++ "/pkgroot";
const TXZ = BASE_DIR ++ "/base-" ++ RELEASE ++ ".txz";

/// Parts of the base system not needed to run Renux (as the shell script
/// skipped them): debug info, tests, headers, 32-bit compat, documentation
/// and the boot loader files.
const BASE_EXCLUDES = [_][]const u8{
    "usr/lib/debug",      "usr/tests",      "usr/include",
    "usr/lib32",          "usr/share/doc",  "usr/share/man",
    "usr/share/examples", "usr/share/i18n", "rescue",
    "boot",
};

const Ctx = struct {
    io: Io,
    a: Allocator,
    client: *std.http.Client,
};

fn say(ctx: Ctx, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(ctx.io, &buf);
    w.interface.print(fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    const a: Allocator = init.arena.allocator();
    const io: Io = init.io;
    const args = try init.minimal.args.toSlice(a);

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const ctx: Ctx = .{ .io = io, .a = a, .client = &client };

    const what: []const u8 = if (args.len >= 2) args[1] else "all";
    const pkgs: []const []const u8 = if (args.len > 2) args[2..] else &.{ "bash", "nano" };

    if (std.mem.eql(u8, what, "base")) {
        try fetchBase(ctx);
    } else if (std.mem.eql(u8, what, "pkgs")) {
        try fetchPkgs(ctx, pkgs);
    } else if (std.mem.eql(u8, what, "all")) {
        try fetchBase(ctx);
        try fetchPkgs(ctx, pkgs);
    } else {
        std.process.fatal("usage: fetch [base|pkgs|all] [package ...]", .{});
    }
}

// -- downloads ---------------------------------------------------------------

/// Download `url` to `dest`. A non-200 status removes the file and stops.
fn download(ctx: Ctx, url: []const u8, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var out = try cwd.createFile(ctx.io, dest, .{});
    var buf: [64 * 1024]u8 = undefined;
    var w = out.writer(ctx.io, &buf);
    const res = try ctx.client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &w.interface,
    });
    try w.interface.flush();
    out.close(ctx.io);
    if (@backingInt(res.status) != 200) {
        cwd.deleteFile(ctx.io, dest) catch {};
        std.process.fatal("fetch: HTTP {d} for {s}", .{ @backingInt(res.status), url });
    }
}

fn fileExists(ctx: Ctx, path: []const u8) bool {
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return false;
    f.close(ctx.io);
    return true;
}

fn readSmall(ctx: Ctx, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.a, .unlimited) catch null;
}

/// Lowercase hex SHA-256 of a file, streamed.
fn sha256Hex(ctx: Ctx, path: []const u8) ![64]u8 {
    const f = try Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer f.close(ctx.io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(ctx.io, &buf);
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        h.update(chunk);
        r.interface.toss(chunk.len);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

// -- base system -------------------------------------------------------------

fn fetchBase(ctx: Ctx) !void {
    const cwd = Io.Dir.cwd();
    const want = RELEASE ++ "." ++ LAYOUT;
    if (readSmall(ctx, ROOT ++ "/.release")) |got| {
        if (std.mem.eql(u8, std.mem.trim(u8, got, " \t\r\n"), want)) {
            say(ctx, "fetch: FreeBSD {s} already in {s}", .{ RELEASE, ROOT });
            return;
        }
    }

    try cwd.createDirPath(ctx.io, BASE_DIR);
    if (!fileExists(ctx, TXZ)) {
        say(ctx, "fetch: downloading {s}", .{BASE_URL});
        try download(ctx, BASE_URL, TXZ);
    }

    say(ctx, "fetch: checking {s}", .{TXZ});
    const sum = try sha256Hex(ctx, TXZ);
    if (!std.mem.eql(u8, &sum, BASE_SHA256)) {
        cwd.deleteFile(ctx.io, TXZ) catch {};
        std.process.fatal("fetch: checksum mismatch for {s}", .{TXZ});
    }

    // Unpack into a scratch tree and swap it in only when it is complete, so a
    // download or decompression error never leaves a half-removed root.
    const tmp = ROOT ++ ".tmp";
    say(ctx, "fetch: unpacking into {s}", .{tmp});
    cwd.deleteTree(ctx.io, tmp) catch {};
    try extractTxz(ctx, TXZ, tmp, &BASE_EXCLUDES);
    try cwd.writeFile(ctx.io, .{ .sub_path = tmp ++ "/.release", .data = want });
    cwd.deleteTree(ctx.io, ROOT) catch {};
    try cwd.rename(tmp, cwd, ROOT, ctx.io);
    say(ctx, "fetch: {s} ready in {s}", .{ RELEASE, ROOT });
}

fn isExcluded(rel: []const u8, excludes: []const []const u8) bool {
    for (excludes) |ex| {
        if (std.mem.eql(u8, rel, ex)) return true;
        if (std.mem.startsWith(u8, rel, ex) and rel.len > ex.len and rel[ex.len] == '/') return true;
    }
    return false;
}

// -- tar extraction ----------------------------------------------------------
//
// std.tar only creates directories, regular files and symlinks; the FreeBSD
// base archive holds ~12800 hard links (grep, vi, halt, ...), which it drops.
// It also calls Reader.discard(), which std.compress.xz leaves unimplemented.
// So the archive is unpacked here: a small tar reader that understands the pax
// and GNU long-name records, creates hard links (by copying their target,
// since Io.Dir has no link()), and only ever reads or streams -- never
// discards.

fn readFull(reader: *Io.Reader, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const got = try reader.readSliceShort(buf[n..]);
        if (got == 0) break;
        n += got;
    }
    return n;
}

/// Read one decimal number terminated by '\n', counting the bytes read in
/// `consumed` (GNU sparse 1.0 writes its map as decimal text in the stream).
fn readDecLine(reader: *Io.Reader, consumed: *u64) !u64 {
    var v: u64 = 0;
    while (true) {
        var b: [1]u8 = undefined;
        if (try readFull(reader, &b) < 1) return error.UnexpectedEof;
        consumed.* += 1;
        const c = b[0];
        if (c == '\n') break;
        if (c >= '0' and c <= '9') v = v * 10 + (c - '0');
    }
    return v;
}

fn skipBytes(reader: *Io.Reader, n: u64) !void {
    var scratch: [8192]u8 = undefined;
    var left = n;
    while (left > 0) {
        const want: usize = @intCast(@min(left, scratch.len));
        const got = try reader.readSliceShort(scratch[0..want]);
        if (got == 0) return error.UnexpectedEof;
        left -= got;
    }
}

/// Bytes of padding after `size` bytes of content, to the next 512 block.
fn pad(size: u64) u64 {
    return (512 - (size % 512)) % 512;
}

fn octal(b: []const u8) u64 {
    var v: u64 = 0;
    for (b) |c| {
        if (c == 0 or c == ' ') continue;
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

fn cstr(b: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, b, 0) orelse b.len;
    return b[0..end];
}

fn fullPath(ctx: Ctx, dest: []const u8, rel: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ dest, rel });
}

/// The pax/GNU extended attributes that apply to the following member.
const Pax = struct {
    path: ?[]u8 = null,
    link: ?[]u8 = null,
    size: ?u64 = null,
    /// GNU.sparse.realsize / GNU.sparse.size: the size of a sparse file once
    /// its holes are filled in.
    realsize: ?u64 = null,
    /// Sparse map (GNU.sparse.map, or repeated .offset/.numbytes pairs):
    /// flattened as offset, length, offset, length ...
    map: std.ArrayListUnmanaged(u64) = .empty,

    fn reset(self: *Pax) void {
        self.path = null;
        self.link = null;
        self.size = null;
        self.realsize = null;
        self.map.clearRetainingCapacity();
    }
};

fn parseMap(ctx: Ctx, val: []const u8, map: *std.ArrayListUnmanaged(u64)) void {
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |tok| {
        const v = std.fmt.parseInt(u64, std.mem.trim(u8, tok, " "), 10) catch continue;
        map.append(ctx.a, v) catch {};
    }
}

/// Parse a pax extended header payload: records of "<len> <key>=<value>\n".
fn parsePax(ctx: Ctx, payload: []const u8, pax: *Pax) void {
    var i: usize = 0;
    while (i < payload.len) {
        const sp = std.mem.findScalarPos(u8, payload, i, ' ') orelse break;
        const len = std.fmt.parseInt(usize, payload[i..sp], 10) catch break;
        if (len == 0 or i + len > payload.len) break;
        const rec = std.mem.trimEnd(u8, payload[sp + 1 .. i + len], "\n");
        if (std.mem.findScalar(u8, rec, '=')) |eq| {
            const key = rec[0..eq];
            const val = rec[eq + 1 ..];
            if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "GNU.sparse.name")) {
                pax.path = ctx.a.dupe(u8, val) catch null;
            } else if (std.mem.eql(u8, key, "linkpath")) {
                pax.link = ctx.a.dupe(u8, val) catch null;
            } else if (std.mem.eql(u8, key, "size")) {
                pax.size = std.fmt.parseInt(u64, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "GNU.sparse.realsize") or std.mem.eql(u8, key, "GNU.sparse.size")) {
                pax.realsize = std.fmt.parseInt(u64, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "GNU.sparse.map")) {
                parseMap(ctx, val, &pax.map);
            } else if (std.mem.eql(u8, key, "GNU.sparse.offset")) {
                const v = std.fmt.parseInt(u64, val, 10) catch continue;
                pax.map.append(ctx.a, v) catch {};
            } else if (std.mem.eql(u8, key, "GNU.sparse.numbytes")) {
                const v = std.fmt.parseInt(u64, val, 10) catch continue;
                pax.map.append(ctx.a, v) catch {};
            }
        }
        i += len;
    }
}

/// Unpack the tar `reader` into `dest`, skipping `excludes`.
fn untar(ctx: Ctx, reader: *Io.Reader, dest: []const u8, excludes: []const []const u8) !void {
    const cwd = Io.Dir.cwd();
    var hdr: [512]u8 = undefined;
    var longname: ?[]u8 = null;
    var longlink: ?[]u8 = null;
    var pax: Pax = .{};
    while (true) {
        const n = try readFull(reader, &hdr);
        if (n == 0) break;
        if (n < 512) return error.UnexpectedEof;
        if (std.mem.allEqual(u8, &hdr, 0)) continue; // end-of-archive blocks

        const typeflag = hdr[156];
        var size = octal(hdr[124..136]);
        var name = cstr(hdr[0..100]);
        var link = cstr(hdr[157..257]);

        // pax ('x'/'g') and GNU ('L'/'K') records apply to the next real
        // header: consume them and loop.
        if (typeflag == 'x' or typeflag == 'g' or typeflag == 'L' or typeflag == 'K') {
            const payload = try ctx.a.alloc(u8, @intCast(size));
            if (try readFull(reader, payload) < payload.len) return error.UnexpectedEof;
            switch (typeflag) {
                'x' => parsePax(ctx, payload, &pax),
                'L' => longname = payload,
                'K' => longlink = payload,
                else => {},
            }
            try skipBytes(reader, pad(size));
            continue;
        }

        const prefix = cstr(hdr[345..500]);
        if (prefix.len > 0) name = try std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ prefix, name });
        if (longname) |v| {
            name = cstr(v);
            longname = null;
        }
        if (longlink) |v| {
            link = cstr(v);
            longlink = null;
        }
        if (pax.path) |v| name = v;
        if (pax.link) |v| link = v;
        if (pax.size) |v| size = v;
        const mode = octal(hdr[100..108]);

        const rel = relPath(name);
        const skip = rel == null or isExcluded(rel.?, excludes);

        // GNU sparse files: the stream holds only the non-hole chunks -- with,
        // for format 1.0, a decimal map at its start -- which are laid back
        // into a zeroed file of the real size.
        if (pax.realsize != null) {
            const real: u64 = pax.realsize.?;
            if (skip) {
                try skipBytes(reader, size);
            } else {
                var consumed: u64 = 0;
                if (pax.map.items.len == 0) {
                    const count = try readDecLine(reader, &consumed);
                    var k: u64 = 0;
                    while (k < count) : (k += 1) {
                        pax.map.append(ctx.a, try readDecLine(reader, &consumed)) catch {};
                        pax.map.append(ctx.a, try readDecLine(reader, &consumed)) catch {};
                    }
                }
                const buf = try ctx.a.alloc(u8, @intCast(real));
                @memset(buf, 0);
                var j: usize = 0;
                while (j + 1 < pax.map.items.len) : (j += 2) {
                    const off = pax.map.items[j];
                    const len = pax.map.items[j + 1];
                    if (off + len > real) break;
                    const got = try readFull(reader, buf[@intCast(off)..@intCast(off + len)]);
                    consumed += got;
                    if (got < len) break;
                }
                if (consumed < size) try skipBytes(reader, size - consumed);
                const p = try fullPath(ctx, dest, rel.?);
                if (std.fs.path.dirname(p)) |d| try cwd.createDirPath(ctx.io, d);
                const out = try cwd.createFile(ctx.io, p, .{});
                defer out.close(ctx.io);
                var sparse_buf: [64 * 1024]u8 = undefined;
                var sw = out.writer(ctx.io, &sparse_buf);
                try sw.interface.writeAll(buf);
                try sw.interface.flush();
            }
            try skipBytes(reader, pad(size));
            pax.reset();
            continue;
        }

        switch (typeflag) {
            '5' => {
                if (!skip) try cwd.createDirPath(ctx.io, try fullPath(ctx, dest, rel.?));
            },
            '0', 0 => {
                if (skip) {
                    try skipBytes(reader, size);
                } else {
                    const p = try fullPath(ctx, dest, rel.?);
                    if (std.fs.path.dirname(p)) |d| try cwd.createDirPath(ctx.io, d);
                    const perm: Io.File.Permissions = if ((mode & 0o111) != 0) .executable_file else .default_file;
                    const out = try cwd.createFile(ctx.io, p, .{ .permissions = perm });
                    defer out.close(ctx.io);
                    var wbuf: [16 * 1024]u8 = undefined;
                    var w = out.writer(ctx.io, &wbuf);
                    try reader.streamExact64(&w.interface, size);
                    try w.interface.flush();
                }
            },
            '2' => {
                if (!skip) {
                    const p = try fullPath(ctx, dest, rel.?);
                    if (std.fs.path.dirname(p)) |d| try cwd.createDirPath(ctx.io, d);
                    cwd.deleteFile(ctx.io, p) catch {};
                    try cwd.symLink(ctx.io, link, p, .{});
                }
            },
            '1' => {
                // A hard link to an earlier member: create it by copying the
                // target (Io.Dir has no link()). If the target was excluded,
                // the link goes too.
                if (!skip) {
                    if (relPath(link)) |tr| {
                        const src = try fullPath(ctx, dest, tr);
                        const dstp = try fullPath(ctx, dest, rel.?);
                        if (std.fs.path.dirname(dstp)) |d| try cwd.createDirPath(ctx.io, d);
                        copyFile(ctx, src, dstp) catch {};
                    }
                }
            },
            else => try skipBytes(reader, size),
        }
        try skipBytes(reader, pad(size));
        pax.reset();
    }
}

/// Copy the file at `src` to `dst`, keeping its permissions: a hard link is
/// the same file, so it must stay executable when its target is.
fn copyFile(ctx: Ctx, src: []const u8, dst: []const u8) !void {
    const cwd: Io.Dir = Io.Dir.cwd();
    try Io.Dir.copyFile(cwd, src, cwd, dst, ctx.io, .{});
}

/// Extract an xz-compressed tar into `dest`, skipping `excludes`.
fn extractTxz(ctx: Ctx, path: []const u8, dest: []const u8, excludes: []const []const u8) !void {
    const cwd = Io.Dir.cwd();
    const src = try cwd.openFile(ctx.io, path, .{});
    defer src.close(ctx.io);
    var fbuf: [128 * 1024]u8 = undefined;
    var fr = src.reader(ctx.io, &fbuf);
    const window = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(window);
    var xz = try std.compress.xz.Decompress.init(&fr.interface, ctx.a, window);
    try cwd.createDirPath(ctx.io, dest);
    try untar(ctx, &xz.reader, dest, excludes);
}

/// `name` as a path relative to the extraction root: without leading slashes,
/// and null when it is empty or tries to climb out with "..".
fn relPath(name: []const u8) ?[]const u8 {
    var rel = std.mem.trimStart(u8, name, "/");
    if (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    if (rel.len == 0 or std.mem.endsWith(u8, rel, "/")) {
        if (rel.len == 0) return null;
    }
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return null;
    }
    return rel;
}

// -- packages ----------------------------------------------------------------

const Pkg = struct { repopath: []const u8, sum: []const u8, name: []const u8, version: []const u8 };

fn fetchPkgs(ctx: Ctx, names: []const []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (!fileExists(ctx, ROOT ++ "/.release")) try fetchBase(ctx);
    try cwd.createDirPath(ctx.io, PKG_DIR ++ "/cache");

    say(ctx, "fetch: getting the {s} catalog", .{ABI});
    try download(ctx, REPO ++ "/packagesite.pkg", PKG_DIR ++ "/packagesite.pkg");
    cwd.deleteTree(ctx.io, PKG_DIR ++ "/catalog") catch {};
    try extractZstdTar(ctx, PKG_DIR ++ "/packagesite.pkg", PKG_DIR ++ "/catalog");

    const cat = PKG_DIR ++ "/catalog/packagesite.yaml";
    const pubkey = cat ++ ".pub";
    const sig = cat ++ ".sig";

    // 1. The signing key must be one FreeBSD trusts.
    const fp = try sha256Hex(ctx, pubkey);
    if (!try trustedContains(ctx, ROOT ++ "/usr/share/keys/pkg/trusted", &fp)) {
        std.process.fatal("fetch: the catalog's signing key ({s}) is not trusted", .{&fp});
    }
    // 2. The signature covers the hexadecimal SHA-256 of the catalog.
    const digest = try sha256Hex(ctx, cat);
    try verifyRsa(ctx, pubkey, sig, &digest);
    say(ctx, "fetch: catalog signature verified (key {s})", .{&fp});

    // 3. Resolve the named packages and their dependencies.
    var list: std.ArrayListUnmanaged(Pkg) = .empty;
    try resolve(ctx, &list, cat, names);

    // 4. Download, check and unpack each one.
    for (list.items) |p| {
        const file = try std.fmt.allocPrint(ctx.a, "{s}/cache/{s}-{s}.pkg", .{ PKG_DIR, p.name, p.version });
        if (!fileExists(ctx, file) or !try pkgSumMatches(ctx, file, p.sum)) {
            say(ctx, "fetch: downloading {s}-{s}", .{ p.name, p.version });
            try download(ctx, try std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ REPO, p.repopath }), file);
        }
        if (!try pkgSumMatches(ctx, file, p.sum)) {
            cwd.deleteFile(ctx.io, file) catch {};
            std.process.fatal("fetch: checksum mismatch for {s}-{s}", .{ p.name, p.version });
        }
        try extractZstdTar(ctx, file, PKGROOT);
    }
    cwd.deleteFile(ctx.io, PKGROOT ++ "/+MANIFEST") catch {};
    cwd.deleteFile(ctx.io, PKGROOT ++ "/+COMPACT_MANIFEST") catch {};
    say(ctx, "fetch: packages ready in {s}", .{PKGROOT});
}

/// Whether any file in `dir` pins `fingerprint` (`fingerprint: "<hex>"`).
fn trustedContains(ctx: Ctx, dir_path: []const u8, fingerprint: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer dir.close(ctx.io);
    var needle_buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "fingerprint: \"{s}\"", .{fingerprint});
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ dir_path, entry.name });
        const data = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.a, .unlimited) catch continue;
        if (std.mem.find(u8, data, needle) != null) return true;
    }
    return false;
}

/// Verify an RSA PKCS#1 v1.5 SHA-256 signature of `msg` (the PEM public key in
/// `pub_path`, the binary signature in `sig_path`).
fn verifyRsa(ctx: Ctx, pub_path: []const u8, sig_path: []const u8, msg: []const u8) !void {
    const rsa = std.crypto.Certificate.rsa;
    const pem = Io.Dir.cwd().readFileAlloc(ctx.io, pub_path, ctx.a, .unlimited) catch return error.NoPublicKey;
    const der = try pemToDer(ctx.a, pem);
    const parsed = try rsaFromSpki(der);
    const key = try rsa.PublicKey.fromBytes(parsed.exponent, parsed.modulus);
    const sig = Io.Dir.cwd().readFileAlloc(ctx.io, sig_path, ctx.a, .unlimited) catch return error.NoSignature;
    switch (sig.len) {
        256 => try rsa.PKCS1v1_5Signature.verify(256, @ptrCast(sig.ptr), msg, key, std.crypto.hash.sha2.Sha256),
        384 => try rsa.PKCS1v1_5Signature.verify(384, @ptrCast(sig.ptr), msg, key, std.crypto.hash.sha2.Sha256),
        512 => try rsa.PKCS1v1_5Signature.verify(512, @ptrCast(sig.ptr), msg, key, std.crypto.hash.sha2.Sha256),
        else => return error.BadSignatureLength,
    }
}

/// The RSA public key inside a DER SubjectPublicKeyInfo ("PUBLIC KEY" PEM):
/// unwrap the outer sequence, the algorithm identifier and the bit string,
/// leaving the RSAPublicKey sequence parseDer() expects.
fn rsaFromSpki(bytes: []const u8) !RsaKey {
    const D = std.crypto.Certificate.der;
    const outer = try D.Element.parse(bytes, 0);
    if (outer.identifier.tag != .sequence) return error.BadPublicKey;
    const alg = try D.Element.parse(bytes, outer.slice.start);
    const bits = try D.Element.parse(bytes, alg.slice.end);
    if (bits.identifier.tag != .bitstring) return error.BadPublicKey;
    // A BIT STRING starts with one byte holding the unused-bit count.
    const inner = bytes[@as(usize, bits.slice.start) + 1 .. @as(usize, bits.slice.end)];
    const k = try std.crypto.Certificate.rsa.PublicKey.parseDer(inner);
    return .{ .modulus = k.modulus, .exponent = k.exponent };
}

const RsaKey = struct { modulus: []const u8, exponent: []const u8 };

/// The DER bytes of a PEM "PUBLIC KEY" (strip the armour, base64-decode).
fn pemToDer(a: Allocator, pem: []const u8) ![]u8 {
    const body = try a.alloc(u8, pem.len);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, pem, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0 or std.mem.startsWith(u8, t, "-----")) continue;
        @memcpy(body[n..][0..t.len], t);
        n += t.len;
    }
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(body[0..n]);
    const der = try a.alloc(u8, size);
    try dec.decode(der, body[0..n]);
    return der;
}

/// Extract a zstd-compressed tar (a FreeBSD .pkg) into `dest`.
fn extractZstdTar(ctx: Ctx, path: []const u8, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    var fbuf: [128 * 1024]u8 = undefined;
    var fr = file.reader(ctx.io, &fbuf);
    const window = try std.heap.page_allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer std.heap.page_allocator.free(window);
    var zstd: std.compress.zstd.Decompress = .init(&fr.interface, window, .{});

    try cwd.createDirPath(ctx.io, dest);
    try untar(ctx, &zstd.reader, dest, &.{});
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

/// Whether `path`'s checksum is the catalog's "sum" field for it.
fn pkgSumMatches(ctx: Ctx, path: []const u8, want: []const u8) !bool {
    const f = try Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer f.close(ctx.io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(ctx.io, &buf);
    var h: std.crypto.hash.blake2.Blake2b512 = .init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        h.update(chunk);
        r.interface.toss(chunk.len);
    }
    var digest: [64]u8 = undefined;
    h.final(&digest);
    var enc: [128]u8 = undefined;
    const s = base32(&digest, &enc);
    // pkg writes the field as "2$" followed by the base32 digest.
    if (want.len < 2 or want[0] != '2' or want[1] != '$') return false;
    return std.mem.eql(u8, s, want[2..]);
}

/// The value of `"key":"..."` in one catalog line, without parsing it all.
fn field(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const pat = "\"" ++ key ++ "\":\"";
    const at = std.mem.find(u8, line, pat) orelse return null;
    const start = at + pat.len;
    const end = std.mem.findScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

/// Resolve `names` and their dependencies (dependencies first) into `list`.
fn resolve(ctx: Ctx, list: *std.ArrayListUnmanaged(Pkg), cat_path: []const u8, names: []const []const u8) !void {
    const catalog = try Io.Dir.cwd().readFileAlloc(ctx.io, cat_path, ctx.a, .unlimited);
    var lines: std.StringHashMapUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, catalog, '\n');
    while (it.next()) |line| {
        const name = field(line, "name") orelse continue;
        try lines.put(ctx.a, name, line);
    }
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (names) |n| try visit(ctx, list, &lines, &done, n);
}

fn visit(
    ctx: Ctx,
    list: *std.ArrayListUnmanaged(Pkg),
    lines: *std.StringHashMapUnmanaged([]const u8),
    done: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (done.contains(name)) return;
    try done.put(ctx.a, name, {});
    const line = lines.get(name) orelse
        std.process.fatal("fetch: no package named {s} in the catalog", .{name});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ctx.a, line, .{});
    const obj = parsed.object;
    if (obj.get("deps")) |deps| {
        var dit = deps.object.iterator();
        while (dit.next()) |e| try visit(ctx, list, lines, done, e.key_ptr.*);
    }
    try list.append(ctx.a, .{
        .repopath = obj.get("repopath").?.string,
        .sum = obj.get("sum").?.string,
        .name = name,
        .version = obj.get("version").?.string,
    });
}
