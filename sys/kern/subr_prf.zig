// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Kernel formatted output and panic.
//
// Mirrors the role of sys/kern/subr_prf.c in NetBSD: printf and its helpers,
// plus panic(). All output goes through the MI console switch (sys/dev/cons.zig),
// so this file is machine independent and names no driver.

const arch: type = @import("../arch/arch.zig");
const cons: type = @import("../dev/cons.zig");

/// Size of the kernel message buffer (a ring, as FreeBSD's msgbuf).
pub const MSGBUF_SIZE: usize = 16384;

var msgbuf: [MSGBUF_SIZE]u8 = undefined;
var msg_head: usize = 0; // next write position
var msg_count: usize = 0; // valid bytes

/// Emit one character on the console and record it in the message buffer.
pub fn putchar(c: u8) void {
    msgbuf[msg_head] = c;
    msg_head = (msg_head + 1) % MSGBUF_SIZE;
    if (msg_count < MSGBUF_SIZE) {
        msg_count += 1;
    }
    cons.cnputc(c);
}

/// Copy the kernel message buffer into `dst`, oldest byte first, returning the
/// number of bytes copied.
pub fn msgbufCopy(dst: []u8) usize {
    const n: usize = if (msg_count < dst.len) msg_count else dst.len;
    var start: usize = (msg_head + MSGBUF_SIZE - msg_count) % MSGBUF_SIZE;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = msgbuf[start];
        start = (start + 1) % MSGBUF_SIZE;
    }
    return n;
}

/// Emit a byte string.
pub fn print(s: []const u8) void {
    for (s) |c| {
        putchar(c);
    }
}

/// Emit a byte string followed by a newline. The console driver turns the
/// newline into a carriage return plus newline where required.
pub fn printLine(s: []const u8) void {
    print(s);
    print("\n");
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}

/// Print `value` as 16 hexadecimal digits prefixed with "0x".
pub fn printHex(value: u64) void {
    print("0x");
    var shift: u6 = 60;
    while (true) {
        const nibble: u8 = @as(u8, @truncate(value >> shift)) & 0x0f;
        putchar(hexDigit(nibble));
        if (shift == 0) {
            break;
        }
        shift -= 4;
    }
}

/// Print a pointer as "0x" followed by 16 hexadecimal digits.
pub fn printPtr(value: u64) void {
    printHex(value);
}

/// Print `value` in hexadecimal without leading zeros, prefixed with "0x".
pub fn printHexTrim(value: u64) void {
    print("0x");
    var started: bool = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u8 = @as(u8, @truncate(value >> shift)) & 0x0f;
        if (nibble != 0 or started or shift == 0) {
            started = true;
            putchar(hexDigit(nibble));
        }
        if (shift == 0) {
            break;
        }
        shift -= 4;
    }
}

/// Print `value` in decimal.
pub fn printDec(value: u64) void {
    if (value == 0) {
        putchar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v: u64 = value;
    while (v != 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    print(buf[i..]);
}

/// Print a signed value in decimal.
pub fn printSigned(value: i64) void {
    if (value < 0) {
        putchar('-');
        printDec(@intCast(-value));
    } else {
        printDec(@intCast(value));
    }
}

/// Minimal printf. Supported conversions:
///
///   %%  literal percent      %c  single character
///   %s  byte string          %u  unsigned decimal
///   %d  signed decimal       %x  hexadecimal (prefixed with 0x)
///   %p  pointer (hex)
///
/// The format string is comptime known, so the argument list is type checked
/// and the loop is fully unrolled.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    comptime var arg_index: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] != '%') {
            putchar(fmt[i]);
            i += 1;
        } else if (i + 1 == fmt.len) {
            putchar('%');
            i += 1;
        } else {
            const spec: u8 = fmt[i + 1];
            i += 2;
            switch (spec) {
                '%' => putchar('%'),
                'c' => putchar(@intCast(args[arg_index])),
                's' => print(args[arg_index]),
                'u' => printDec(@intCast(args[arg_index])),
                'd' => printSigned(@intCast(args[arg_index])),
                'x' => printHex(@intCast(args[arg_index])),
                'p' => printPtr(@intFromPtr(args[arg_index])),
                else => {
                    putchar('%');
                    putchar(spec);
                },
            }
            if (spec != '%') {
                arg_index += 1;
            }
        }
    }
}

/// Fatal kernel error. Reports to the console and halts the CPU forever.
///
/// The signature matches Zig's panic hook so this can be installed as the
/// kernel panic handler from the root source file.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    printLine("");
    printLine("!!!! KERNEL PANIC !!!!");
    printLine(msg);
    if (first_trace_addr) |addr| {
        print("  at ");
        printHex(addr);
        printLine("");
    }
    // Stop the machine through the machine-dependent primitives; MI code never
    // issues cli/hlt directly.
    arch.cpu.disable_interrupts();
    arch.cpu.idle();
}
