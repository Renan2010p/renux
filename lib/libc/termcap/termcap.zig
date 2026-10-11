// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// termcap.
//
// A small termcap implementation with a built-in vt100-like description, so a
// program can get terminal capabilities without a terminfo database on disk.
// The functions match the classic termcap(3) API (tgetent, tgetstr, tgetnum,
// tgetflag, tgoto, tputs).

const syscall: type = @import("../sys/syscall.zig");

const Cap: type = struct {
    name: []const u8,
    value: [*:0]const u8,
};

const caps: []const Cap = &.{
    .{ .name = "cl", .value = "\x1b[H\x1b[2J" }, // clear screen
    .{ .name = "ce", .value = "\x1b[K" }, // clear to end of line
    .{ .name = "cm", .value = "\x1b[%i%d;%dH" }, // cursor motion
    .{ .name = "ho", .value = "\x1b[H" }, // home
    .{ .name = "up", .value = "\x1b[A" },
    .{ .name = "do", .value = "\x1b[B" },
    .{ .name = "le", .value = "\x1b[D" },
    .{ .name = "nd", .value = "\x1b[C" },
    .{ .name = "cr", .value = "\r" },
    .{ .name = "md", .value = "\x1b[1m" }, // bold
    .{ .name = "me", .value = "\x1b[0m" }, // end attributes
    .{ .name = "so", .value = "\x1b[7m" }, // standout
    .{ .name = "se", .value = "\x1b[0m" },
    .{ .name = "ku", .value = "\x1b[A" }, // arrow keys
    .{ .name = "kd", .value = "\x1b[B" },
    .{ .name = "kl", .value = "\x1b[D" },
    .{ .name = "kr", .value = "\x1b[C" },
    .{ .name = "bl", .value = "\x07" }, // bell
};

fn nameEqual(name: [*:0]const u8, want: []const u8) bool {
    var i: usize = 0;
    while (i < want.len) : (i += 1) {
        if (name[i] == 0 or name[i] != want[i]) {
            return false;
        }
    }
    return name[want.len] == 0;
}

/// tgetent: always succeed (there is no database).
pub export fn tgetent(bp: ?[*]u8, name: [*:0]const u8) c_int {
    _ = bp;
    _ = name;
    return 1;
}

/// tgetstr: the escape sequence for capability `name`, or null.
pub export fn tgetstr(name: [*:0]const u8, area: ?[*]?[*]u8) ?[*]u8 {
    _ = area;
    for (caps) |cap| {
        if (nameEqual(name, cap.name)) {
            return @constCast(cap.value);
        }
    }
    return null;
}

/// tgetnum: the numeric value of capability `name`, or -1.
pub export fn tgetnum(name: [*:0]const u8) c_int {
    if (nameEqual(name, "co")) {
        return 80;
    }
    if (nameEqual(name, "li")) {
        return 24;
    }
    return -1;
}

/// tgetflag: whether boolean capability `name` is set.
pub export fn tgetflag(name: [*:0]const u8) c_int {
    if (nameEqual(name, "am")) {
        return 1;
    }
    return 0;
}

fn putChar(c: u8) void {
    _ = syscall.write(1, &.{c});
}

fn putInt(v: c_int) void {
    if (v < 0) {
        putChar('-');
        return putInt(-v);
    }
    const x: c_int = v;
    if (x >= 10) {
        putInt(@divTrunc(x, 10));
    }
    putChar(@intCast(@as(c_int, '0') + @rem(x, 10)));
}

/// tgoto: build a cursor-motion string for the given position.
pub export fn tgoto(cm: [*:0]const u8, destcol: c_int, destrow: c_int) [*:0]u8 {
    // Result is kept in a static buffer (as termcap allows).
    const S: type = struct {
        var buf: [32]u8 = undefined;
    };
    var n: usize = 0;
    var col: c_int = destcol;
    var row: c_int = destrow;
    var i: usize = 0;
    while (cm[i] != 0 and n < S.buf.len - 1) {
        const c = cm[i];
        if (c != '%') {
            S.buf[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        switch (cm[i]) {
            'i' => {
                col += 1;
                row += 1;
                i += 1;
            },
            'r' => {
                const t = col;
                col = row;
                row = t;
                i += 1;
            },
            'd' => {
                // Emit the (already incremented) row then column.
                n = writeInt(S.buf[0..], n, row);
                row = col;
                i += 1;
            },
            '%' => {
                S.buf[n] = '%';
                n += 1;
                i += 1;
            },
            else => i += 1,
        }
    }
    S.buf[n] = 0;
    return @ptrCast(&S.buf[0]);
}

fn writeInt(buf: []u8, start: usize, v: c_int) usize {
    var n: usize = start;
    var tmp: [12]u8 = undefined;
    var k: usize = 0;
    var x: c_int = if (v < 0) -v else v;
    if (x == 0) {
        tmp[0] = '0';
        k = 1;
    }
    while (x > 0) {
        tmp[k] = @intCast(@as(c_int, '0') + @rem(x, 10));
        k += 1;
        x = @divTrunc(x, 10);
    }
    if (v < 0) {
        buf[n] = '-';
        n += 1;
    }
    var j: usize = k;
    while (j > 0) {
        j -= 1;
        buf[n] = tmp[j];
        n += 1;
    }
    return n;
}

/// tputs: write `cp` to the terminal, ignoring padding markers ($<...>).
pub export fn tputs(cp: [*:0]const u8, affcnt: c_int, outc: *const fn (c_int) callconv(.c) void) c_int {
    _ = affcnt;
    var i: usize = 0;
    while (cp[i] != 0) {
        if (cp[i] == '$' and cp[i + 1] == '<') {
            i += 2;
            while (cp[i] != 0 and cp[i] != '>') : (i += 1) {}
            if (cp[i] == '>') {
                i += 1;
            }
            continue;
        }
        outc(cp[i]);
        i += 1;
    }
    return 0;
}
