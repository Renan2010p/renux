// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The kernel random number generator.
//
// The counterpart of FreeBSD's sys/dev/random/randomdev.c: read_random(9)
// for the kernel and getrandom(2) (core/sys_getrandom.zig) for programs.
// Output is a ChaCha20 keystream whose key is reseeded from every registered
// entropy source plus the CPU's cycle counter and the time of day, and
// replaced after each request (forward secrecy).
//
// This file is machine independent: hardware sources live in their own
// files and register themselves (random_source_register(), as FreeBSD's
// ivy.c does for RDRAND), and the cycle counter comes from the port's
// get_cyclecount(). Without a hardware source the seed is only the cycle
// counter and the time, which an observer can largely predict: good enough
// for hash seeds and libc's arc4random() bring-up, NOT for cryptographic
// keys. A real entropy pool (interrupt timing, virtio-rng, the TPM) is still
// to be written.

const arch: type = @import("../../arch/arch.zig");
const kern_time: type = @import("../../core/kern_time.zig");

/// An entropy source (FreeBSD's struct random_source): `read` fills `buf`
/// and returns how many bytes it produced.
pub const Source: type = struct {
    ident: []const u8,
    read: *const fn (buf: []u8) usize,
};

const MAX_SOURCES: usize = 4;
var sources: [MAX_SOURCES]?*const Source = @splat(null);

/// Add a hardware entropy source (FreeBSD's random_source_register()).
pub fn random_source_register(src: *const Source) void {
    for (&sources) |*slot| {
        if (slot.* == null) {
            slot.* = src;
            return;
        }
    }
}

var key: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
var counter: u64 = 0;
var seeded: bool = false;

fn rotl(x: u32, n: u5) u32 {
    return (x << n) | (x >> @intCast(@as(u6, 32) - n));
}

fn quarter(s: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    s[a] +%= s[b];
    s[d] = rotl(s[d] ^ s[a], 16);
    s[c] +%= s[d];
    s[b] = rotl(s[b] ^ s[c], 12);
    s[a] +%= s[b];
    s[d] = rotl(s[d] ^ s[a], 8);
    s[c] +%= s[d];
    s[b] = rotl(s[b] ^ s[c], 7);
}

/// One ChaCha20 block of keystream for the current key and counter.
fn block(out: *[64]u8) void {
    const init: [16]u32 = .{
        0x61707865,         0x3320646e,               0x79622d32, 0x6b206574,
        key[0],             key[1],                   key[2],     key[3],
        key[4],             key[5],                   key[6],     key[7],
        @truncate(counter), @truncate(counter >> 32), 0,          0,
    };
    var s: [16]u32 = init;
    var r: usize = 0;
    while (r < 10) : (r += 1) {
        quarter(&s, 0, 4, 8, 12);
        quarter(&s, 1, 5, 9, 13);
        quarter(&s, 2, 6, 10, 14);
        quarter(&s, 3, 7, 11, 15);
        quarter(&s, 0, 5, 10, 15);
        quarter(&s, 1, 6, 11, 12);
        quarter(&s, 2, 7, 8, 13);
        quarter(&s, 3, 4, 9, 14);
    }
    for (&s, init, 0..) |*w, orig, i| {
        w.* +%= orig;
        out[i * 4 + 0] = @truncate(w.*);
        out[i * 4 + 1] = @truncate(w.* >> 8);
        out[i * 4 + 2] = @truncate(w.* >> 16);
        out[i * 4 + 3] = @truncate(w.* >> 24);
    }
    counter += 1;
}

/// Mix fresh seed material into the key.
fn reseed() void {
    var seed: [32]u8 = @splat(0);
    for (sources) |slot| {
        const src: *const Source = slot orelse continue;
        var b: [32]u8 = undefined;
        const n: usize = src.read(&b);
        for (b[0..@min(n, 32)], 0..) |v, i| seed[i] ^= v;
    }
    var i: usize = 0;
    while (i < 8) : (i += 2) {
        const v: u64 = arch.machine_cpu.get_cyclecount() ^ (kern_time.now() *% 0x9e3779b97f4a7c15);
        key[i] ^= @as(u32, @truncate(v)) ^ word(&seed, i);
        key[i + 1] ^= @as(u32, @truncate(v >> 32)) ^ word(&seed, i + 1);
    }
    // Run the keystream once so the new key depends on the old one too.
    var b: [64]u8 = undefined;
    block(&b);
    for (&key, 0..) |*k, j| k.* ^= word(b[0..32], j);
    seeded = true;
}

fn word(b: []const u8, j: usize) u32 {
    return @as(u32, b[j * 4]) | (@as(u32, b[j * 4 + 1]) << 8) |
        (@as(u32, b[j * 4 + 2]) << 16) | (@as(u32, b[j * 4 + 3]) << 24);
}

/// Fill `buf` with random bytes (FreeBSD's read_random(9)).
pub fn read_random(buf: []u8) void {
    if (!seeded or (counter & 0xff) == 0) reseed();
    var off: usize = 0;
    while (off < buf.len) {
        var b: [64]u8 = undefined;
        block(&b);
        const n: usize = @min(64, buf.len - off);
        @memcpy(buf[off .. off + n], b[0..n]);
        off += n;
    }
    // Forward secrecy: replace the key with fresh keystream after use.
    var nk: [64]u8 = undefined;
    block(&nk);
    for (&key, 0..) |*k, j| k.* = word(nk[0..32], j);
}

// -- /dev/random -------------------------------------------------------------------

const conf: type = @import("../../sys/conf.zig");
const errno: type = @import("../../sys/errno.zig");
const sysinit: type = @import("../../sys/sysinit.zig");

/// Major number of /dev/random (and /dev/urandom, which is the same device
/// on FreeBSD).
pub const RANDOM_MAJOR: usize = 6;

fn randomOpen(dev: u64, flags: i32) ?*anyopaque {
    _ = dev;
    _ = flags;
    return null;
}

fn randomRead(ctx: ?*anyopaque, buf: []u8) isize {
    _ = ctx;
    read_random(buf);
    return @intCast(buf.len);
}

/// Writes are accepted and discarded (FreeBSD mixes them into the pool).
fn randomWrite(ctx: ?*anyopaque, buf: []const u8) isize {
    _ = ctx;
    return @intCast(buf.len);
}

fn randomIoctl(ctx: ?*anyopaque, cmd: u64, arg: u64) i32 {
    _ = ctx;
    _ = cmd;
    _ = arg;
    return -errno.ENOTTY;
}

fn randomClose(ctx: ?*anyopaque) i32 {
    _ = ctx;
    return 0;
}

const random_cdevsw: conf.Cdevsw = .{
    .name = "random",
    .open = randomOpen,
    .read = randomRead,
    .write = randomWrite,
    .ioctl = randomIoctl,
    .close = randomClose,
};

fn randomAttach(_: ?*const anyopaque) callconv(.c) void {
    conf.registerCdev(RANDOM_MAJOR, &random_cdevsw);
}

comptime {
    sysinit.SYSINIT("sysinit_randomdev", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_THIRD, randomAttach, null);
}
