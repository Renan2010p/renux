// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 memory primitives.
//
// The counterpart of FreeBSD's sys/amd64/amd64/support.S: memcpy, memmove,
// memset, memcmp, bcmp and strlen for this port. They are machine dependent
// (x86-64 assembly), so they live with the port, not in kern/; each port
// provides its own. The kernel is built without SIMD (see sys/build.zig) and
// without compiler_rt, so these are the routines every @memcpy and @memset
// compiles to. They never touch the SSE registers, which belong to the user
// program the kernel is running for.

/// memcpy(3): copy `n` bytes; the regions must not overlap.
///
/// Eight bytes per move, four moves per loop, in general registers: fast on
/// hardware and under emulators alike (QEMU's TCG runs the string
/// instructions one element at a time), and the compiler cannot turn the
/// assembly back into a call to memcpy.
pub export fn memcpy() callconv(.naked) void {
    asm volatile (
        \\ movq %%rdi, %%rax
        \\ movq %%rdx, %%rcx
        \\ shrq $5, %%rcx
        \\ jz 2f
        \\1:
        \\ movq 0(%%rsi), %%r8
        \\ movq 8(%%rsi), %%r9
        \\ movq 16(%%rsi), %%r10
        \\ movq 24(%%rsi), %%r11
        \\ movq %%r8, 0(%%rdi)
        \\ movq %%r9, 8(%%rdi)
        \\ movq %%r10, 16(%%rdi)
        \\ movq %%r11, 24(%%rdi)
        \\ addq $32, %%rsi
        \\ addq $32, %%rdi
        \\ decq %%rcx
        \\ jnz 1b
        \\2:
        \\ movq %%rdx, %%rcx
        \\ andq $31, %%rcx
        \\ shrq $3, %%rcx
        \\ jz 4f
        \\3:
        \\ movq (%%rsi), %%r8
        \\ movq %%r8, (%%rdi)
        \\ addq $8, %%rsi
        \\ addq $8, %%rdi
        \\ decq %%rcx
        \\ jnz 3b
        \\4:
        \\ andq $7, %%rdx
        \\ jz 6f
        \\5:
        \\ movb (%%rsi), %%r8b
        \\ movb %%r8b, (%%rdi)
        \\ incq %%rsi
        \\ incq %%rdi
        \\ decq %%rdx
        \\ jnz 5b
        \\6:
        \\ ret
    );
}

/// memmove(3): copy `n` bytes; the regions may overlap. When the
/// destination overlaps the source from above it copies backwards, else it
/// is memcpy.
pub export fn memmove() callconv(.naked) void {
    asm volatile (
        \\ movq %%rdi, %%rax
        \\ cmpq %%rsi, %%rdi
        \\ jbe 7f
        \\ leaq (%%rsi,%%rdx), %%r8
        \\ cmpq %%r8, %%rdi
        \\ jae 7f
        \\ leaq -1(%%rsi,%%rdx), %%rsi
        \\ leaq -1(%%rdi,%%rdx), %%rdi
        \\ testq %%rdx, %%rdx
        \\ jz 9f
        \\8:
        \\ movb (%%rsi), %%r8b
        \\ movb %%r8b, (%%rdi)
        \\ decq %%rsi
        \\ decq %%rdi
        \\ decq %%rdx
        \\ jnz 8b
        \\9:
        \\ ret
        \\7:
        \\ jmp memcpy
    );
}

/// memset(3): fill `n` bytes with `c`, eight bytes per store.
pub export fn memset() callconv(.naked) void {
    asm volatile (
        \\ movq %%rdi, %%rax
        \\ movzbq %%sil, %%r8
        \\ movabsq $0x0101010101010101, %%r9
        \\ imulq %%r9, %%r8
        \\ movq %%rdx, %%rcx
        \\ shrq $5, %%rcx
        \\ jz 2f
        \\1:
        \\ movq %%r8, 0(%%rdi)
        \\ movq %%r8, 8(%%rdi)
        \\ movq %%r8, 16(%%rdi)
        \\ movq %%r8, 24(%%rdi)
        \\ addq $32, %%rdi
        \\ decq %%rcx
        \\ jnz 1b
        \\2:
        \\ andq $31, %%rdx
        \\ jz 4f
        \\3:
        \\ movb %%r8b, (%%rdi)
        \\ incq %%rdi
        \\ decq %%rdx
        \\ jnz 3b
        \\4:
        \\ ret
    );
}

/// memcmp(3): compare `n` bytes.
pub export fn memcmp(a: ?[*]const u8, b: ?[*]const u8, n: usize) callconv(.c) c_int {
    @setRuntimeSafety(false);
    const pa: [*]const u8 = a orelse return 0;
    const pb: [*]const u8 = b orelse return 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pa[i] != pb[i]) return @as(c_int, pa[i]) - @as(c_int, pb[i]);
    }
    return 0;
}

/// bcmp(3): zero when the `n` bytes are equal (the compiler emits it for
/// equality comparisons).
pub export fn bcmp(a: ?[*]const u8, b: ?[*]const u8, n: usize) callconv(.c) c_int {
    return memcmp(a, b, n);
}

/// strlen(3) (the compiler turns NUL-terminated scans into calls to it).
pub export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}
