// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Calendar conversions.
//
// The Zig counterpart of FreeBSD's sys/kern/subr_clock.c: convert between a
// broken-down UTC calendar time (what a real-time clock chip holds) and seconds
// since the Unix epoch, and format a time the way ctime(3) does for the boot
// log. It is pure arithmetic, so it is unit tested on the host.

/// A broken-down UTC time (FreeBSD's struct clocktime, without nanoseconds).
pub const ClockTime: type = struct {
    year: u32, // e.g. 2026
    mon: u32, // 1..12
    day: u32, // 1..31
    hour: u32, // 0..23
    min: u32, // 0..59
    sec: u32, // 0..59
};

/// Days from 1970-01-01 to the civil date y-m-d (Howard Hinnant's algorithm,
/// exact over the proleptic Gregorian calendar).
fn daysFromCivil(year: u32, mon: u32, day: u32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(mon <= 2);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const m: i64 = mon;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Seconds since the epoch for `ct` (FreeBSD's clock_ct_to_ts()). Returns null
/// when a field is out of range, e.g. an unset or corrupt RTC.
pub fn toEpoch(ct: ClockTime) ?i64 {
    if (ct.year < 1970 or ct.mon < 1 or ct.mon > 12 or ct.day < 1 or ct.day > 31 or
        ct.hour > 23 or ct.min > 59 or ct.sec > 60)
    {
        return null;
    }
    const days: i64 = daysFromCivil(ct.year, ct.mon, ct.day);
    return days * 86400 + @as(i64, ct.hour) * 3600 + @as(i64, ct.min) * 60 + ct.sec;
}

/// The broken-down UTC time for `secs` since the epoch (FreeBSD's
/// clock_ts_to_ct()).
pub fn fromEpoch(secs: i64) ClockTime {
    const days: i64 = @divFloor(secs, 86400);
    const rem: i64 = secs - days * 86400;

    const z: i64 = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const y: i64 = yoe + era * 400 + @intFromBool(m <= 2);

    return .{
        .year = @intCast(y),
        .mon = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(rem, 3600)),
        .min = @intCast(@divFloor(@mod(rem, 3600), 60)),
        .sec = @intCast(@mod(rem, 60)),
    };
}

const wday_names: [7][]const u8 = .{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const mon_names: [12][]const u8 = .{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Length of the text formatTime() produces.
pub const TIME_LEN: usize = 28;

fn put2(out: []u8, v: u32, pad: u8) void {
    out[0] = if (v < 10) pad else '0' + @as(u8, @intCast(v / 10));
    out[1] = '0' + @as(u8, @intCast(v % 10));
}

/// Format `secs` as ctime(3) does, in UTC: "Mon Oct 12 19:32:26 UTC 2026".
pub fn formatTime(secs: i64, out: *[TIME_LEN]u8) []const u8 {
    const ct: ClockTime = fromEpoch(secs);
    // 1970-01-01 was a Thursday, the first entry of wday_names.
    const wday: usize = @intCast(@mod(@divFloor(secs, 86400), 7));
    @memcpy(out[0..3], wday_names[wday]);
    out[3] = ' ';
    @memcpy(out[4..7], mon_names[ct.mon - 1]);
    out[7] = ' ';
    put2(out[8..10], ct.day, ' ');
    out[10] = ' ';
    put2(out[11..13], ct.hour, '0');
    out[13] = ':';
    put2(out[14..16], ct.min, '0');
    out[16] = ':';
    put2(out[17..19], ct.sec, '0');
    @memcpy(out[19..24], " UTC ");
    var y: u32 = ct.year;
    var i: usize = 28;
    while (i > 24) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(y % 10));
        y /= 10;
    }
    return out[0..TIME_LEN];
}

const testing = @import("std").testing;

test "toEpoch and fromEpoch agree on known dates" {
    try testing.expectEqual(@as(?i64, 0), toEpoch(.{ .year = 1970, .mon = 1, .day = 1, .hour = 0, .min = 0, .sec = 0 }));
    try testing.expectEqual(@as(?i64, 1767225600), toEpoch(.{ .year = 2026, .mon = 1, .day = 1, .hour = 0, .min = 0, .sec = 0 }));
    // A leap day.
    try testing.expectEqual(@as(?i64, 1709210096), toEpoch(.{ .year = 2024, .mon = 2, .day = 29, .hour = 12, .min = 34, .sec = 56 }));
    const ct: ClockTime = fromEpoch(1709210096);
    try testing.expectEqual(ClockTime{ .year = 2024, .mon = 2, .day = 29, .hour = 12, .min = 34, .sec = 56 }, ct);
}

test "fromEpoch round-trips across years" {
    var t: i64 = 0;
    while (t < 4_102_444_800) : (t += 86_399 * 37) { // to 2100, odd step
        try testing.expectEqual(@as(?i64, t), toEpoch(fromEpoch(t)));
    }
}

test "formatTime matches ctime" {
    var buf: [TIME_LEN]u8 = undefined;
    try testing.expectEqualStrings("Mon Oct 12 22:32:26 UTC 2026", formatTime(1791844346, &buf));
    try testing.expectEqualStrings("Thu Jan  1 00:00:00 UTC 1970", formatTime(0, &buf));
}

test "toEpoch rejects an unset clock" {
    try testing.expectEqual(@as(?i64, null), toEpoch(.{ .year = 2026, .mon = 0, .day = 0, .hour = 0, .min = 0, .sec = 0 }));
    try testing.expectEqual(@as(?i64, null), toEpoch(.{ .year = 2026, .mon = 13, .day = 1, .hour = 0, .min = 0, .sec = 0 }));
}
