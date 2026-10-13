// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Loader environment and loader.conf.
//
// The counterpart of FreeBSD's stand/common/environment.c plus the loader.conf
// reader in stand/lua/config.lua: a small table of name=value variables, filled
// from /boot/defaults/loader.conf and then /boot/loader.conf, changed with the
// `set`/`unset` commands and read by the menu and the boot code. Variable names
// follow FreeBSD (autoboot_delay, boot_verbose, boot_single, kernel, ...) so
// the same knobs work the same way.

const platform: type = @import("platform");

const MAX_VARS: usize = 64;
const NAME_MAX: usize = 48;
const VALUE_MAX: usize = 160;

const Var: type = struct {
    name: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    value: [VALUE_MAX]u8 = undefined,
    value_len: usize = 0,
    used: bool = false,

    fn nameSlice(v: *const Var) []const u8 {
        return v.name[0..v.name_len];
    }

    fn valueSlice(v: *const Var) []const u8 {
        return v.value[0..v.value_len];
    }
};

var vars: [MAX_VARS]Var = @splat(.{});

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn find(name: []const u8) ?*Var {
    for (&vars) |*v| {
        if (v.used and eql(v.nameSlice(), name)) return v;
    }
    return null;
}

/// The value of `name`, or null when it is not set.
pub fn get(name: []const u8) ?[]const u8 {
    const v = find(name) orelse return null;
    return v.valueSlice();
}

/// Set `name` to `value`. Returns false when the table is full or a string is
/// too long.
pub fn set(name: []const u8, value: []const u8) bool {
    if (name.len == 0 or name.len > NAME_MAX or value.len > VALUE_MAX) return false;
    const v: *Var = find(name) orelse blk: {
        for (&vars) |*slot| {
            if (!slot.used) break :blk slot;
        }
        return false;
    };
    @memcpy(v.name[0..name.len], name);
    v.name_len = name.len;
    @memcpy(v.value[0..value.len], value);
    v.value_len = value.len;
    v.used = true;
    return true;
}

/// Remove `name`.
pub fn unset(name: []const u8) void {
    if (find(name)) |v| v.used = false;
}

/// True when `name` is set to a yes value ("YES", "yes", "1", "on").
pub fn isYes(name: []const u8) bool {
    const v = get(name) orelse return false;
    return eql(v, "YES") or eql(v, "yes") or eql(v, "Yes") or eql(v, "1") or eql(v, "on");
}

/// The value of `name` as a number, or `default`.
pub fn getNumber(name: []const u8, default: u64) u64 {
    const v = get(name) orelse return default;
    var n: u64 = 0;
    if (v.len == 0) return default;
    for (v) |c| {
        if (c < '0' or c > '9') return default;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// Print every variable, as `show` does.
pub fn show() void {
    for (&vars) |*v| {
        if (!v.used) continue;
        platform.print(v.nameSlice());
        platform.print("=");
        platform.print(v.valueSlice());
        platform.print("\n");
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isSpace(s[a])) a += 1;
    while (b > a and isSpace(s[b - 1])) b -= 1;
    return s[a..b];
}

/// Parse one `name="value"` assignment (also `name=value`), ignoring
/// comments. Returns false on a malformed line.
pub fn assign(line_in: []const u8) bool {
    var line: []const u8 = line_in;
    // Strip a comment that is not inside quotes.
    var in_quote: bool = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quote = !in_quote;
        if (c == '#' and !in_quote) {
            line = line[0..i];
            break;
        }
    }
    line = trim(line);
    if (line.len == 0) return true;
    var eq: usize = 0;
    while (eq < line.len and line[eq] != '=') eq += 1;
    if (eq == line.len) return false;
    const name: []const u8 = trim(line[0..eq]);
    var value: []const u8 = trim(line[eq + 1 ..]);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return set(name, value);
}

/// Read a loader.conf file. Prints "Loading <path>" as FreeBSD's loader does,
/// only when the file exists. Returns false when it does not.
pub fn loadConf(path: []const u8) bool {
    const data: []const u8 = platform.readFile(path) orelse return false;
    platform.print("Loading ");
    platform.print(path);
    platform.print("\n");
    var start: usize = 0;
    var lineno: usize = 1;
    var i: usize = 0;
    while (i <= data.len) : (i += 1) {
        if (i == data.len or data[i] == '\n') {
            if (!assign(data[start..i])) {
                platform.printf("{s}:{d}: syntax error\n", .{ path, lineno });
            }
            start = i + 1;
            lineno += 1;
        }
    }
    return true;
}
