// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The loader environment and loader.conf.
//
// The counterpart of FreeBSD's stand/common/environment.c plus the
// loader.conf reader in stand/lua/config.lua. The environment is a small,
// fixed table of name=value variables:
//
//   - filled from /boot/defaults/loader.conf, then /boot/loader.conf and
//     /boot/loader.conf.local (bootloader/efi/main.zig);
//   - changed by the menu and by the `set` and `unset` commands;
//   - read by the menu and by the hand-off, which turns some variables into
//     kernel arguments.
//
// Variable names follow FreeBSD (autoboot_delay, boot_verbose, boot_single,
// console, kernel, kernels, ...), so the same knobs work the same way.

const std: type = @import("std");
const platform: type = @import("platform");

const MAX_VARS: usize = 64;
const NAME_MAX: usize = 48;
const VALUE_MAX: usize = 160;

/// One slot of the table.
const Var: type = struct {
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    value_buf: [VALUE_MAX]u8 = undefined,
    value_len: usize = 0,
    used: bool = false,

    fn name(v: *const Var) []const u8 {
        return v.name_buf[0..v.name_len];
    }

    fn value(v: *const Var) []const u8 {
        return v.value_buf[0..v.value_len];
    }
};

var vars: [MAX_VARS]Var = @splat(.{});

/// The slot holding `name`, or null when it is not set.
fn find(name: []const u8) ?*Var {
    for (&vars) |*v| {
        if (v.used and std.mem.eql(u8, v.name(), name)) return v;
    }
    return null;
}

/// A free slot, or null when the table is full.
fn freeSlot() ?*Var {
    for (&vars) |*v| {
        if (!v.used) return v;
    }
    return null;
}

/// The value of `name`, or null when it is not set.
pub fn get(name: []const u8) ?[]const u8 {
    const v: *const Var = find(name) orelse return null;
    return v.value();
}

/// Set `name` to `value`. Returns false when the table is full or a string
/// is too long.
pub fn set(name: []const u8, value: []const u8) bool {
    if (name.len == 0 or name.len > NAME_MAX or value.len > VALUE_MAX) return false;
    const v: *Var = find(name) orelse freeSlot() orelse return false;
    @memcpy(v.name_buf[0..name.len], name);
    v.name_len = name.len;
    @memcpy(v.value_buf[0..value.len], value);
    v.value_len = value.len;
    v.used = true;
    return true;
}

/// Remove `name`.
pub fn unset(name: []const u8) void {
    if (find(name)) |v| v.used = false;
}

/// The values FreeBSD's loader accepts as "yes".
const YES_VALUES: []const []const u8 = &.{ "YES", "yes", "Yes", "1", "on" };

/// True when `name` is set to a yes value ("YES", "yes", "Yes", "1", "on").
pub fn isYes(name: []const u8) bool {
    const value: []const u8 = get(name) orelse return false;
    for (YES_VALUES) |yes| {
        if (std.mem.eql(u8, value, yes)) return true;
    }
    return false;
}

/// The value of `name` as a decimal number, or `default` when it is not set
/// or not a number.
pub fn getNumber(name: []const u8, default: u64) u64 {
    const value: []const u8 = get(name) orelse return default;
    return parseDecimal(value) orelse default;
}

/// `text` as an unsigned decimal number: digits only, no sign, no
/// separators. Returns null for anything else.
pub fn parseDecimal(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseUnsigned(u64, text, 10) catch null;
}

/// Print every variable as name=value, as the `show` command does.
pub fn show() void {
    for (&vars) |*v| {
        if (!v.used) continue;
        platform.printf("{s}={s}\n", .{ v.name(), v.value() });
    }
}

/// Characters that surround names and values in loader.conf.
const BLANKS: []const u8 = " \t\r";

/// Apply one loader.conf line: `name="value"` or `name=value`, with an
/// optional `# comment` outside the quotes. Blank and comment-only lines are
/// accepted and do nothing. Returns false on a malformed line.
pub fn assign(line: []const u8) bool {
    const code: []const u8 = std.mem.trim(u8, stripComment(line), BLANKS);
    if (code.len == 0) return true;
    const eq: usize = std.mem.indexOfScalar(u8, code, '=') orelse return false;
    const name: []const u8 = std.mem.trim(u8, code[0..eq], BLANKS);
    var value: []const u8 = std.mem.trim(u8, code[eq + 1 ..], BLANKS);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return set(name, value);
}

/// `line` without a `#` comment that starts outside double quotes.
fn stripComment(line: []const u8) []const u8 {
    var in_quotes: bool = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '"' => in_quotes = !in_quotes,
            '#' => if (!in_quotes) return line[0..i],
            else => {},
        }
    }
    return line;
}

/// Read a loader.conf file into the environment. When the file exists it
/// prints "Loading <path>" as FreeBSD's loader does, and reports each
/// malformed line. Returns false when there is no such file.
pub fn loadConf(path: []const u8) bool {
    const data: []u8 = platform.readFile(path) orelse return false;
    defer platform.freeFile(data);
    platform.printf("Loading {s}\n", .{path});
    var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, data, '\n');
    var lineno: usize = 1;
    while (lines.next()) |line| : (lineno += 1) {
        if (!assign(line)) {
            platform.printf("{s}:{d}: syntax error\n", .{ path, lineno });
        }
    }
    return true;
}
