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

/// FreeBSD's bootverbose: set by `boot -v` (the `-v` or `boot_verbose` kernel
/// argument). The terse boot log shows only what FreeBSD shows; subsystems keep
/// their internal progress messages behind this flag.
pub var bootverbose: bool = false;

/// Record one character in the message buffer only (what dmesg(8) reads).
fn msgbufPutc(c: u8) void {
    msgbuf[msg_head] = c;
    msg_head = (msg_head + 1) % MSGBUF_SIZE;
    if (msg_count < MSGBUF_SIZE) {
        msg_count += 1;
    }
}

/// Emit one character on the console and record it in the message buffer.
pub fn putchar(c: u8) void {
    msgbufPutc(c);
    cons.cnputc(c);
}

/// Mark the start of a boot in the message buffer, as FreeBSD's msgbuf does,
/// so dmesg(8) output begins with "---<<BOOT>>---". It is not shown on the
/// console.
pub fn msgbufBootMark() void {
    for ("---<<BOOT>>---\n") |c| {
        msgbufPutc(c);
    }
}

/// Emit a byte string on the console only, bypassing the message buffer. For
/// output that belongs to the loader stage (the spinner, "Loading kernel...")
/// and would only clutter dmesg(8).
pub fn cnprint(s: []const u8) void {
    for (s) |c| {
        cons.cnputc(c);
    }
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

/// Print `value` as FreeBSD's "%b" conversion does: the value in hexadecimal,
/// then the names of the set bits in angle brackets, comma separated, e.g.
/// `0x78bfbfd<FPU,DE,PSE,...>`. `names[i]` names bit i; set bits without a name
/// are shown as `b<i>`.
pub fn printBits(value: u64, names: []const []const u8) void {
    printHexTrim(value);
    if (value == 0) {
        return;
    }
    putchar('<');
    var first: bool = true;
    var bit: u7 = 0;
    while (bit < 64) : (bit += 1) {
        if ((value >> @intCast(bit)) & 1 == 0) {
            continue;
        }
        if (!first) {
            putchar(',');
        }
        first = false;
        if (bit < names.len and names[bit].len > 0) {
            print(names[bit]);
        } else {
            putchar('b');
            printDec(bit);
        }
    }
    putchar('>');
}

/// Minimal printf. Supported conversions:
///
///   %%  literal percent      %c  single character
///   %s  byte string          %u  unsigned decimal
///   %d  signed decimal       %x  hexadecimal, no leading zeros (0x...)
///   %p  pointer (16 hex digits)
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
                'x' => printHexTrim(@intCast(args[arg_index])),
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

// BSD syslog priorities, as sys/sys/syslog.h defines them. `log()` emits a
// message only when its priority passes the current filter, exactly as
// FreeBSD's log(9) (sys/kern/subr_prf.c) does.
pub const LOG_EMERG: u8 = 0; // system is unusable
pub const LOG_ALERT: u8 = 1; // action must be taken immediately
pub const LOG_CRIT: u8 = 2; // critical conditions
pub const LOG_ERR: u8 = 3; // error conditions
pub const LOG_WARNING: u8 = 4; // warning conditions
pub const LOG_NOTICE: u8 = 5; // normal but significant condition
pub const LOG_INFO: u8 = 6; // informational
pub const LOG_DEBUG: u8 = 7; // debug-level messages

/// Most verbose priority that reaches the console; anything numerically greater
/// is dropped (FreeBSD's `log_max`, defaulting to LOG_INFO).
var log_max: u8 = LOG_INFO;

/// Set the log filter, as a `kern.log_max`-style tunable would.
pub fn setLogMax(level: u8) void {
    log_max = level;
}

/// FreeBSD's log(9): format a message and emit it subject to the priority
/// filter. Subsystems report boot progress through this rather than raw
/// printf(), so a single knob can quiet them. Informational messages
/// (LOG_INFO and below in severity) are only shown under bootverbose, which
/// keeps the default boot log as terse as FreeBSD's; warnings and errors are
/// always shown.
pub fn log(comptime level: u8, comptime fmt: []const u8, args: anytype) void {
    if (level > log_max) {
        return;
    }
    if (level >= LOG_INFO and !bootverbose) {
        return;
    }
    printf(fmt, args);
    putchar('\n');
}

// The boot spinner, in the spirit of FreeBSD's boot2 (stand/i386/boot2/boot2.c),
// which redraws one glyph in place with "\b \b". The kernel shows it while it
// unpacks the embedded root image.

/// Spinner glyphs, in order.
const spin_frames: []const u8 = "|/-\\";

var spin_frame: usize = 0;
var spin_open: bool = false;

// The spinner writes to the console only: it is loader-stage decoration and
// would fill the message buffer with backspaces.

/// Open a spinner line `label`; spin() advances it and spinEnd() closes it.
pub fn spinBegin(label: []const u8) void {
    cnprint(label);
    cons.cnputc(spin_frames[0]);
    spin_frame = 1;
    spin_open = true;
}

/// Advance the spinner one frame.
pub fn spin() void {
    if (!spin_open) {
        return;
    }
    cons.cnputc(0x08); // backspace: redraw over the previous glyph
    cons.cnputc(spin_frames[spin_frame]);
    spin_frame = (spin_frame + 1) % spin_frames.len;
}

/// Close the spinner line.
pub fn spinEnd() void {
    if (!spin_open) {
        return;
    }
    // Erase the glyph so the finished line reads "<label>done".
    cons.cnputc(0x08);
    cnprint("done\n");
    spin_open = false;
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
