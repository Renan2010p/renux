// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Time formatting.
//
// The Zig counterpart of NetBSD's lib/libc/gen/ctime.c, reduced to ctime(3):
// it turns a Unix time into "Www Mmm dd hh:mm:ss YYYY\n" (UTC).

const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

var buf: [26]u8 = undefined;

fn put2(out: []u8, at: usize, v: i64) void {
    out[at] = @intCast('0' + @divTrunc(@rem(v, 100), 10));
    out[at + 1] = @intCast('0' + @rem(v, 10));
}

fn put4(out: []u8, at: usize, v: i64) void {
    out[at] = @intCast('0' + @rem(@divTrunc(v, 1000), 10));
    out[at + 1] = @intCast('0' + @rem(@divTrunc(v, 100), 10));
    out[at + 2] = @intCast('0' + @rem(@divTrunc(v, 10), 10));
    out[at + 3] = @intCast('0' + @rem(v, 10));
}

/// ctime(3): format `*t` into a static string, or null when `t` is null.
pub export fn ctime(t: ?*const i64) ?[*:0]u8 {
    const p = t orelse return null;
    const secs: i64 = p.*;

    var days: i64 = @divFloor(secs, 86400);
    var rem: i64 = secs - days * 86400;
    if (rem < 0) {
        rem += 86400;
        days -= 1;
    }
    const hour: i64 = @divTrunc(rem, 3600);
    const min: i64 = @divTrunc(@rem(rem, 3600), 60);
    const sec: i64 = @rem(rem, 60);

    var wd: i64 = @rem(days + 4, 7);
    if (wd < 0) {
        wd += 7;
    }

    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: i64 = @divTrunc(5 * doy + 2, 153);
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    if (m <= 2) {
        y += 1;
    }

    const w: []const u8 = wdays[@intCast(wd)];
    buf[0] = w[0];
    buf[1] = w[1];
    buf[2] = w[2];
    buf[3] = ' ';
    const mo: []const u8 = months[@intCast(m - 1)];
    buf[4] = mo[0];
    buf[5] = mo[1];
    buf[6] = mo[2];
    buf[7] = ' ';
    buf[8] = if (d < 10) @as(u8, ' ') else @intCast('0' + @divTrunc(d, 10));
    buf[9] = @intCast('0' + @rem(d, 10));
    buf[10] = ' ';
    put2(buf[0..], 11, hour);
    buf[13] = ':';
    put2(buf[0..], 14, min);
    buf[16] = ':';
    put2(buf[0..], 17, sec);
    buf[19] = ' ';
    put4(buf[0..], 20, y);
    buf[24] = '\n';
    buf[25] = 0;
    return @ptrCast(&buf[0]);
}
