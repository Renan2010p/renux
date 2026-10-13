// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The boot menu.
//
// The counterpart of FreeBSD's stand/lua/menu.lua and drawer.lua: the brand,
// the logo, a frame titled "Welcome to Renux" with the numbered entries, the
// "Boot Options" submenu and the autoboot countdown, laid out at the same
// positions FreeBSD uses. Every entry does what it says:
//
//   1. Boot Multi user [Enter]   boot normally
//   2. Boot Single user          boot with -s (init offers a shell)
//   3. Escape to loader prompt   the OK prompt (interp.zig)
//   4. Reboot
//   5. Cons: ...                 which consoles the kernel attaches
//   6. Kernel: ...               cycles through the `kernels` that exist
//   7. Boot Options              single user and verbose toggles
//
// Settings live in the loader environment (env.zig) under FreeBSD's names
// (boot_single, boot_verbose, console, kernel, kernels, autoboot_delay), so
// loader.conf and the `set` command reach the same knobs.

const platform: type = @import("platform");
const env: type = @import("env.zig");
const gfx: type = @import("gfx_renux.zig");

/// What the menu decided.
pub const Action: type = enum { boot, prompt };

// Layout, as FreeBSD's drawer.lua: the menu text at (5, 10), the frame three
// columns left of it and one row above, 42 x 13.
const MENU_X: usize = 5;
const MENU_Y: usize = 10;
const FRAME_W: usize = 42;
const FRAME_H: usize = 13;

var color: bool = true;

/// Print `s`, highlighting marked characters as FreeBSD's color.highlight()
/// does: `^x` highlights the single character x, `{...}` a whole group.
fn printMarked(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const c: u8 = s[i];
        if (c == '^' and i + 1 < s.len) {
            if (color) platform.setColor(.white, true);
            platform.print(s[i + 1 .. i + 2]);
            if (color) platform.resetColor();
            i += 2;
        } else if (c == '{') {
            var j: usize = i + 1;
            while (j < s.len and s[j] != '}') j += 1;
            if (color) platform.setColor(.white, true);
            platform.print(s[i + 1 .. j]);
            if (color) platform.resetColor();
            i = j + 1;
        } else {
            var j: usize = i;
            while (j < s.len and s[j] != '^' and s[j] != '{') j += 1;
            platform.print(s[i..j]);
            i = j;
        }
    }
}

fn drawFrame(title: []const u8) void {
    const x: usize = MENU_X - 3;
    const y: usize = MENU_Y - 1;
    // Top border with the centred title.
    platform.gotoxy(x, y);
    platform.print("┌");
    const left: usize = (FRAME_W - 2 - title.len) / 2;
    var k: usize = 0;
    while (k < FRAME_W - 2) : (k += 1) {
        if (k == left) {
            platform.print(title);
            k += title.len - 1;
        } else {
            platform.print("─");
        }
    }
    platform.print("┐");
    var r: usize = 1;
    while (r < FRAME_H - 1) : (r += 1) {
        platform.gotoxy(x, y + r);
        platform.print("│");
        platform.gotoxy(x + FRAME_W - 1, y + r);
        platform.print("│");
    }
    platform.gotoxy(x, y + FRAME_H - 1);
    platform.print("└");
    k = 0;
    while (k < FRAME_W - 2) : (k += 1) platform.print("─");
    platform.print("┘");
}

fn clearInside() void {
    var r: usize = 1;
    while (r < FRAME_H - 1) : (r += 1) {
        platform.gotoxy(MENU_X - 2, MENU_Y - 1 + r);
        var k: usize = 0;
        while (k < FRAME_W - 2) : (k += 1) platform.print(" ");
    }
}

fn line(row: usize, text: []const u8) void {
    platform.gotoxy(MENU_X, MENU_Y + row);
    printMarked(text);
}

// -- console and kernel choices -------------------------------------------------

const consoles: [3][]const u8 = .{ "vidconsole comconsole", "vidconsole", "comconsole" };
const console_names: [3][]const u8 = .{ "Dual (Video primary)", "Video", "Serial" };

fn consoleIndex() usize {
    const v: []const u8 = env.get("console") orelse return 0;
    for (consoles, 0..) |c, i| {
        if (eql(c, v)) return i;
    }
    return 0;
}

const MAX_KERNELS: usize = 8;
var kernel_names: [MAX_KERNELS][]const u8 = undefined;
var kernel_count: usize = 0;

/// Collect the entries of `kernels` that exist as /boot/<name>/kernel.
fn scanKernels() void {
    kernel_count = 0;
    const list: []const u8 = env.get("kernels") orelse "kernel";
    var it = Tokens{ .s = list };
    while (it.next()) |name| {
        if (kernel_count == MAX_KERNELS) break;
        var pbuf: [128]u8 = undefined;
        const path: []const u8 = kernelPath(&pbuf, name) orelse continue;
        if (platform.fileSize(path) != null) {
            kernel_names[kernel_count] = name;
            kernel_count += 1;
        }
    }
}

/// "/boot/<dir>/<bootfile>" for kernel directory `dir`.
pub fn kernelPath(buf: []u8, dir: []const u8) ?[]const u8 {
    const file: []const u8 = env.get("bootfile") orelse "kernel";
    const parts: [5][]const u8 = .{ "/boot/", dir, "/", file, "" };
    var n: usize = 0;
    for (parts) |p| {
        if (n + p.len > buf.len) return null;
        @memcpy(buf[n .. n + p.len], p);
        n += p.len;
    }
    return buf[0..n];
}

fn kernelIndex() usize {
    const cur: []const u8 = env.get("kernel") orelse "kernel";
    var i: usize = 0;
    while (i < kernel_count) : (i += 1) {
        if (eql(kernel_names[i], cur)) return i;
    }
    return 0;
}

// -- the menus ---------------------------------------------------------------

fn onOff(name: []const u8) []const u8 {
    return if (env.isYes(name)) "{On}" else "off";
}

fn drawMain() void {
    clearInside();
    line(1, "1. ^Boot ^Multi user {[Enter]}");
    line(2, "2. Boot ^Single user");
    line(3, "3. ^Escape to loader prompt");
    line(4, "4. ^Reboot");
    var b: [96]u8 = undefined;
    line(5, fmt(&b, "5. ^Cons: {s}", .{console_names[consoleIndex()]}));
    line(7, "Options:");
    const k: []const u8 = if (kernel_count > 0) kernel_names[kernelIndex()] else "kernel";
    const default_mark: []const u8 = if (kernelIndex() == 0) "default/" else "";
    line(8, fmt(&b, "6. ^Kernel: {s}{s} ({d} of {d})", .{ default_mark, k, kernelIndex() + 1, @max(kernel_count, 1) }));
    line(9, "7. Boot ^Options");
}

fn drawOptions() void {
    clearInside();
    line(1, "1. Back to main menu {[Backspace]}");
    line(2, "2. ^Load System Defaults");
    line(4, "Boot Options:");
    var b: [96]u8 = undefined;
    line(5, fmt(&b, "3. ^Single user. : {s}", .{onOff("boot_single")}));
    line(6, fmt(&b, "4. ^Verbose..... : {s}", .{onOff("boot_verbose")}));
}

fn toggle(name: []const u8) void {
    if (env.isYes(name)) env.unset(name) else _ = env.set(name, "YES");
}

/// Draw the whole screen: brand, logo and frame.
fn drawScreen() void {
    platform.clear();
    platform.cursor(false);
    gfx.drawBrand();
    gfx.drawLogo(env.get("loader_logo") orelse "renux", color);
    drawFrame(env.get("loader_menu_title") orelse "Welcome to Renux");
}

fn autobootLine(seconds: u64) void {
    platform.gotoxy(4, 23);
    var b: [80]u8 = undefined;
    printMarked(fmt(&b, "Autoboot in {d} second{s}. {{[Space]}} to pause ", .{ seconds, if (seconds == 1) "" else "s" }));
}

fn clearAutobootLine() void {
    platform.gotoxy(4, 23);
    platform.print("                                             ");
}

/// Run the menu until the user (or the autoboot timer) picks an action.
pub fn run() Action {
    color = !eql(env.get("loader_color") orelse "", "NO");
    scanKernels();
    drawScreen();
    drawMain();

    // Autoboot countdown, as FreeBSD's menu.autoboot(): a key stops it.
    // autoboot_delay="NO" or "-1" disables it.
    const ad: []const u8 = env.get("autoboot_delay") orelse "10";
    const delay: u64 = if (eql(ad, "NO") or eql(ad, "-1")) 0 else env.getNumber("autoboot_delay", 10);
    var pending: ?platform.Key = null;
    if (delay > 0) {
        var left: u64 = delay;
        countdown: while (left > 0) : (left -= 1) {
            autobootLine(left);
            var ticks: usize = 0;
            while (ticks < 20) : (ticks += 1) {
                if (platform.getKey()) |key| {
                    clearAutobootLine();
                    if (!(key == .char and key.char == ' ')) pending = key;
                    break :countdown;
                }
                platform.delay(50_000);
            }
        } else {
            clearAutobootLine();
            env.unset("boot_single");
            return .boot;
        }
    }

    var in_options: bool = false;
    while (true) {
        const key: platform.Key = pending orelse platform.waitKey();
        pending = null;
        if (!in_options) {
            switch (key) {
                .enter => {
                    env.unset("boot_single");
                    return .boot;
                },
                .char => |c| switch (lower(c)) {
                    '1', 'b' => {
                        env.unset("boot_single");
                        return .boot;
                    },
                    '2', 's' => {
                        _ = env.set("boot_single", "YES");
                        return .boot;
                    },
                    '3', 'e' => return .prompt,
                    '4', 'r' => platform.reboot(),
                    '5', 'c' => {
                        _ = env.set("console", consoles[(consoleIndex() + 1) % consoles.len]);
                        drawMain();
                    },
                    '6', 'k' => {
                        if (kernel_count > 1) {
                            _ = env.set("kernel", kernel_names[(kernelIndex() + 1) % kernel_count]);
                        }
                        drawMain();
                    },
                    '7', 'o' => {
                        in_options = true;
                        drawOptions();
                    },
                    else => {},
                },
                .escape => return .prompt,
                else => {},
            }
        } else {
            switch (key) {
                .backspace => {
                    in_options = false;
                    drawMain();
                },
                .char => |c| switch (lower(c)) {
                    '1' => {
                        in_options = false;
                        drawMain();
                    },
                    '2', 'l' => {
                        env.unset("boot_single");
                        env.unset("boot_verbose");
                        drawOptions();
                    },
                    '3', 's' => {
                        toggle("boot_single");
                        drawOptions();
                    },
                    '4', 'v' => {
                        toggle("boot_verbose");
                        drawOptions();
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}

/// Leave the menu screen: clear it and restore the cursor.
pub fn finish() void {
    platform.resetColor();
    platform.clear();
    platform.cursor(true);
}

// -- helpers -----------------------------------------------------------------

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return @import("std").fmt.bufPrint(buf, f, args) catch buf[0..0];
}

/// Space-separated words of a string.
pub const Tokens: type = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(t: *Tokens) ?[]const u8 {
        while (t.i < t.s.len and (t.s[t.i] == ' ' or t.s[t.i] == '\t')) t.i += 1;
        if (t.i >= t.s.len) return null;
        const start: usize = t.i;
        while (t.i < t.s.len and t.s[t.i] != ' ' and t.s[t.i] != '\t') t.i += 1;
        return t.s[start..t.i];
    }
};
