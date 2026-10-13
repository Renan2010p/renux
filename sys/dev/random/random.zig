// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Kernel random numbers.
//
// The counterpart of FreeBSD's sys/dev/random (read_random(9) and the
// getrandom(2) system call). Output comes from a ChaCha20 keystream, as in
// FreeBSD's arc4random(9); the key is reseeded from the CPU's RDRAND when it
// has one.
//
// Without RDRAND the only seed material is the TSC and the time of day, which
// an observer can largely predict: good enough for hash seeds and libc's
// arc4random() bring-up, NOT for cryptographic keys. A real entropy pool
// (interrupt timing, virtio-rng, the TPM) is still to be written.

const sys: type = @import("../../sys/syscall.zig");
const errno: type = @import("../../sys/errno.zig");
const cpufunc: type = @import("../../arch/x86/include/cpufunc.zig");
const kern_time: type = @import("../../kern/kern_time.zig");

var key: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
var counter: u64 = 0;
var seeded: bool = false;
var have_rdrand: bool = false;

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// One RDRAND value, or null if the instruction failed (it may, transiently).
fn rdrand() ?u64 {
    var v: u64 = undefined;
    var ok: u8 = undefined;
    asm volatile (
        \\ rdrand %[v]
        \\ setc %[ok]
        : [v] "=r" (v),
          [ok] "=r" (ok),
    );
    return if (ok != 0) v else null;
}

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
    if (!seeded) {
        have_rdrand = (cpufunc.cpuid(1, 0).ecx & (1 << 30)) != 0;
    }
    var i: usize = 0;
    while (i < 8) : (i += 2) {
        var v: u64 = rdtsc() ^ (kern_time.now() *% 0x9e3779b97f4a7c15);
        if (have_rdrand) {
            if (rdrand()) |r| v ^= r;
        }
        key[i] ^= @truncate(v);
        key[i + 1] ^= @truncate(v >> 32);
    }
    // Run the keystream once so the new key depends on the old one too.
    var b: [64]u8 = undefined;
    block(&b);
    for (&key, 0..) |*k, j| k.* ^= @as(u32, b[j * 4]) | (@as(u32, b[j * 4 + 1]) << 8) |
        (@as(u32, b[j * 4 + 2]) << 16) | (@as(u32, b[j * 4 + 3]) << 24);
    seeded = true;
}

/// Fill `buf` with random bytes (FreeBSD's read_random(9)).
pub fn readRandom(buf: []u8) void {
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
    for (&key, 0..) |*k, j| k.* = @as(u32, nk[j * 4]) | (@as(u32, nk[j * 4 + 1]) << 8) |
        (@as(u32, nk[j * 4 + 2]) << 16) | (@as(u32, nk[j * 4 + 3]) << 24);
}

/// getrandom(2): `getrandom(buf, buflen, flags)`. The generator never
/// blocks, so GRND_NONBLOCK and GRND_RANDOM change nothing.
pub fn sysGetrandom(args: [sys.MAXARGS]u64) u64 {
    const GRND_NONBLOCK: u64 = 0x1;
    const GRND_RANDOM: u64 = 0x2;
    const GRND_INSECURE: u64 = 0x4;
    if ((args[2] & ~(GRND_NONBLOCK | GRND_RANDOM | GRND_INSECURE)) != 0) return sys.signed(-errno.EINVAL);
    // FreeBSD caps one call at 256 bytes (getentropy's limit) only in libc;
    // the system call itself accepts more. Bound it to a sane size.
    const len: usize = @intCast(@min(args[1], 1 << 20));
    const dst: [*]u8 = @ptrFromInt(args[0]);
    readRandom(dst[0..len]);
    return len;
}
